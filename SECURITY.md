# Security Policy

## Supported versions

Only the latest `main` and, once one exists, the most recent public release tag receive security fixes. Older releases are not patched.

| Version | Supported |
|---|---|
| `main` (latest commit) | ✅ |
| most recent release tag | not published yet |
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
- The macOS maintenance boundary (`scripts/cleanup.sh`, `scripts/storage_watch.sh`, `scripts/schedule.sh`), including recipe allowlisting, process preconditions, path canonicalization, symlink rejection, approval gating, LaunchAgent generation, and local receipts.
- The landing page's i18n loader (`docs/script.js`) — including XSS via translation JSON.

Out of scope:
- The Sysinternals binaries themselves — report those to Microsoft.
- VirusTotal API behavior — report to virustotal.com.
- User PC misconfigurations.
- Issues requiring physical access or pre-existing admin/root.

## Trust model

- Source release ZIPs ship readable PowerShell / Bash / JXA / Swift source and no compiled diagnostic binary. A future separately published Universal 2 DMG must contain the same allowlisted readable Mac runtime, be Developer ID signed/notarized/stapled/Gatekeeper-assessed, and ship with SHA-256 plus machine-readable tag/commit/architecture/minimum-OS/trust metadata.
- Release building rejects user config, scan output, unsafe archive paths, unexpected symlinks, credential-shaped data, email addresses, and build-machine home paths. The tracked `data/config.example.json` contains no secret; `data/config.json` is ignored and excluded from every artifact.
- The only external binaries the tool executes are Sysinternals `sigcheck.exe` and `autorunsc.exe`, both downloaded from `https://live.sysinternals.com/` and **verified via `Get-AuthenticodeSignature`** against a Microsoft signer subject. Verification runs **on every invocation**, not only at first download — the cache directory under `%LOCALAPPDATA%` is user-writable, so a cached `.exe` is re-validated each run to defend against post-cache tampering by other user-mode malware (the scenario this tool exists to detect). If the signature check fails, the binary is deleted and the tool falls back to a fresh download (which is itself re-verified).
- VirusTotal outbound calls live in `scripts/vt-lookup.ps1` and `scripts/scanner_helper.jxa.js`. Optional Sysinternals downloads live in `scripts/sigcheck-helper.ps1` and `scripts/autorunsc-helper.ps1`. Grep `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api` to audit.
- The Mac cleanup harness never accepts a caller-supplied filesystem path. It resolves a fixed recipe ID to targets under the current user's home or Chrome's temporary clone directory, rejects symlinked/non-canonical targets, and requires `--owner-approved` for execution. Preview is read-only.
- Protected histories (`~/.codex/sessions`, Claude local-agent workspaces), SDKs, Simulator runtimes, and Codex log databases have no executable cleanup recipe. Cleanup receipts are mode `0600` inside a mode `0700` local directory.
- Dynamic app recipes accept a validated bundle ID, independently rediscover matching bundles under `/Applications` or `~/Applications`, block running bundles, and move only exact bundle-ID residue to a unique Trash folder. Xcode identifiers and bundles containing developer SDK/toolchain payloads are rejected. They never accept an app path from scan output.
- Simulator recipes accept a normalized UUID only after `simctl` reports that exact available device. Booted devices, legacy keep entries, and UUIDs in the owner-only keep list are rejected again immediately before deletion; runtime assets are never a target.
- The optional hourly LaunchAgent runs the read-only free-space watcher. Installing or removing it requires explicit approval, and the watcher has no cleanup command.
- Before a standalone invocation, the app validates its sealed bundle signature and compares every bundled runtime file byte-for-byte with the staged mirror. Executable scanner, report, cleanup, schedule, and watcher paths come only from the signed bundle; Application Support holds mutable output and migration state, never executable input. User configuration lives separately at `~/Library/Application Support/PC Health Check/config.json`, is mode `0600`, and is never treated as immutable runtime content.
- Native process execution creates a private process group atomically, drains output with a bound, and terminates the whole group on timeout, cancellation, output overflow, or a root process that leaves descendants behind. During an approved destructive cleanup, normal app termination is deferred until the transaction reports completion or a recoverable receipt state.
- The SwiftUI app contains no LLM client. MCP, skills, plugins, and external AI models are not required for scanning or cleanup and cannot authorize a cleanup action through this release runtime.

## Hall of thanks

People who report verified vulnerabilities are credited here (with their permission) once the fix ships.

_(none yet)_
