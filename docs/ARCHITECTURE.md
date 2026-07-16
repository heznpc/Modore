# Architecture

PC Health Check is an evidence-first local diagnostic tool with two OS-specific runtimes under one product promise. It does not attempt to hide the collectors behind a shared cross-platform abstraction when the operating systems expose different evidence.

## Trust boundaries

1. **Collect** OS facts with readable PowerShell on Windows or Bash/JXA on macOS.
2. **Classify** facts with declarative JSON rules and locale-aware whitelist data.
3. **Present** findings in offline HTML; the Mac edition also uses a native SwiftUI app.
4. **Act only after approval.** Mac cleanup accepts an allowlisted recipe ID, previews fixed targets, checks related processes, and requires a second explicit approval.

Scan results, storage history, cleanup receipts, and local paths are owner data. They are not contribution fixtures and must not be committed or attached to public issues without manual redaction.

## Mac runtime

```text
SwiftUI view
  -> ScanModel
    -> scripts/scanner.sh
      -> macOS shell modules
      -> scanner_helper.jxa.js
      -> rules/*.json + data/whitelist.json
    -> scripts/report.jxa.js
    -> scan_result.json + offline HTML
```

The SwiftUI app owns navigation, local state presentation, approval sheets, and process execution. It mirrors the cleanup recipe catalog only to hide stale/unsupported actions in old scan results; `cleanup.sh` remains the final authority and independently rejects every unknown recipe or changed target.

Every app build embeds an explicit runtime allowlist under `Contents/Resources/runtime`; no build records the developer checkout path. Mutable output stays under `~/Library/Application Support/PC Health Check/results`, separate from the non-executable runtime migration mirror. Production resolution validates the sealed app bundle, binds its active-slice cdhash to the kernel-tracked running process, captures every Bash/JXA/module/rule input, and validates the signature again. The process runner copies those captured bytes into unlinked files and passes only inherited `/dev/fd` handles to interpreters, so later bundle pathname replacement cannot change scanner, report, cleanup, or scheduler bytes. Child processes also start from a fixed minimal environment and pin the runtime working-directory device/inode. User settings remain separate at `~/Library/Application Support/PC Health Check/config.json` (mode `0600`); only `data/config.example.json` is tracked and bundled. Legacy results are copied without overwrite, and unknown files in an old runtime are retained in a `runtime-backup-*` directory instead of being deleted. The hourly watcher uses an exact clean-environment LaunchAgent definition; both its on-disk plist and launchd's loaded program/arguments are revalidated, and unstable DMG/App Translocation paths are rejected. The source launcher asks an existing development app to terminate safely before rebuilding, so an old process cannot be paired with new resources.

## Mac source layout

- `Models/`: scan DTOs, one published content snapshot, storage/history models, and stable selection keys.
- `Services/`: process runner, scan pipeline, view-model orchestration, and standalone runtime staging.
- `Views/`: app shell, native destination lists/forms, storage workspaces, approval sheets, and shared setting components.
- `Support/`: bounded scan-log state plus small presentation and process-safety helpers.
- `Tests/`: pure state, parsing, accounting, and runtime-install tests.

## Cleanup invariants

- No caller-supplied deletion path.
- No cleanup recipe for SDKs, Simulator runtimes, Codex session JSONL, Claude local-agent workspaces, or Codex log databases.
- App removal re-resolves a validated bundle ID instead of trusting a path from scan output.
- Simulator deletion normalizes and revalidates the UUID with `simctl`; Booted, legacy, and owner-preserved UUID states are checked again at the destructive boundary.
- Preview records a 15-minute, owner-only manifest containing canonical paths, measured tree size, process fingerprint, and filesystem identity. Execute requires `--owner-approved` plus its one-time 256-bit token and remeasures immediately before and after the same-volume move.
- Child commands are spawned into a private process group and have bounded output/termination handling. Normal Cmd-Q termination is delayed while an approved destructive transaction is active so cleanup cannot become an unsupervised child.
- Directory traversal uses no-follow, descriptor-relative operations; symlinked or non-canonical targets are rejected at use time.
- A local receipt is written after execution.

## Good contribution areas

- Verified Korean/Japanese application whitelist entries.
- False-positive fixtures that contain no personal scan data.
- New declarative rules with negative tests.
- macOS path attribution that can be proven from bundle IDs or documented tool layouts.
- Translations that preserve the same risk meaning.
- UI accessibility and keyboard-flow improvements that do not weaken approval boundaries.

Changes to outbound networking, signature verification, cleanup targets, standalone runtime staging, or protected-data rules require design discussion and dedicated negative tests.

## Verification map

- `python3 -I -B -m pytest tests/ -q`: rule/report/runtime contracts and destructive-boundary tests in isolated fixtures.
- `swift test --package-path macos/PCHealthCheckMac -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`: native model, selection, history, presentation, and runtime-staging tests under the CI compiler policy.
- `python3 -I -B scripts/release_smoke.py`: OS-specific source allowlists plus secret/PII/archive-structure audit.
- `scripts/package_macos_release.sh --local`: strict Universal 2 standalone app/DMG build under `dist/local/`, clearly unsigned for distribution and never overwriting a release artifact. Git, Swift/Xcode, Python audit, signing, and disk-image tools run from a minimal environment; metadata records the selected developer directory and Swift version.
- `scripts/package_macos_release.sh`: clean exact signed-annotated-tag gate pinned to an externally supplied SSH public-key fingerprint and principal `heznpc`, Git replace-object rejection, source-prefix removal, architecture/minimum-OS validation, payload audit, externally pinned Developer ID Team ID and leaf-certificate SHA-256, hardened runtime, notarytool, stapling, Gatekeeper validation, final source revalidation, and sidecar release metadata when credentials are supplied externally.
