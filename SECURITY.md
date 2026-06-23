# Security Policy

## Supported versions

Only the latest `main` and the most recent release tag receive security fixes. Older releases are not patched — please upgrade.

| Version | Supported |
|---|---|
| `main` (latest commit) | ✅ |
| most recent release tag | ✅ |
| `v0.2.x` and earlier | ❌ |

## Reporting a vulnerability

**Please do not open public GitHub issues for security findings.**

Use GitHub's [Private Vulnerability Reporting](https://github.com/heznpc/pc-health-check/security/advisories/new) — the "Report a vulnerability" button on the repository's Security tab. This routes the report directly to the maintainer without going through public issues.

If Private Vulnerability Reporting is unavailable, use a private maintainer-approved channel and include the subject prefix `[pc-health-check security]`.

### What to include

- Affected file(s) and line numbers (if possible).
- Reproduction steps, including the OS and shell runtime version.
- Expected vs actual behavior.
- Impact assessment (what an attacker can do).
- Optional: suggested fix.

### Response timeline

- **Initial acknowledgement**: within 5 business days.
- **Triage + severity assessment**: within 14 days.
- **Fix or mitigation**: target 90 days from triage. Critical issues (RCE, signature bypass on the Sysinternals download path, secret exfiltration) get faster turnaround.
- **Public disclosure**: coordinated with the reporter. Default is 90 days from triage or upon fix release, whichever comes first.

## Scope

In scope:
- Code in `scripts/`, `rules/`, `docs/`, `data/`, and CI workflows.
- The Sysinternals binary download + verification path (`scripts/sigcheck-helper.ps1`, `scripts/autorunsc-helper.ps1`).
- The VirusTotal integration (`scripts/scanner_helper.jxa.js`, `scripts/vt-lookup.ps1`).
- The HTML report generator's escaping logic (`scripts/report.ps1`, `scripts/report.jxa.js`, `scripts/report.py` for development parity tests).
- The landing page's i18n loader (`docs/script.js`) — including XSS via translation JSON.

Out of scope:
- The Sysinternals binaries themselves — report those to Microsoft.
- VirusTotal API behavior — report to virustotal.com.
- User PC misconfigurations.
- Issues requiring physical access or pre-existing admin/root.

## Trust model

- This project ships runtime releases as readable PowerShell / Bash / JXA source. No compiled binaries are bundled.
- The only external binaries the tool executes are Sysinternals `sigcheck.exe` and `autorunsc.exe`, both downloaded from `https://live.sysinternals.com/` and **verified via `Get-AuthenticodeSignature`** against a Microsoft signer subject. Verification runs **on every invocation**, not only at first download — the cache directory under `%LOCALAPPDATA%` is user-writable, so a cached `.exe` is re-validated each run to defend against post-cache tampering by other user-mode malware (the scenario this tool exists to detect). If the signature check fails, the binary is deleted and the tool falls back to a fresh download (which is itself re-verified).
- VirusTotal outbound calls live in `scripts/vt-lookup.ps1` and `scripts/scanner_helper.jxa.js`. Optional Sysinternals downloads live in `scripts/sigcheck-helper.ps1` and `scripts/autorunsc-helper.ps1`. Grep `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api` to audit.

## Hall of thanks

People who report verified vulnerabilities are credited here (with their permission) once the fix ships.

_(none yet)_
