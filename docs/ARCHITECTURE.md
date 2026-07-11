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

Source builds may use `project-root.txt` for an explicit developer checkout. Standalone builds omit that marker, embed an explicit runtime allowlist under `Contents/Resources/runtime`, and keep mutable output under `~/Library/Application Support/PC Health Check/runtime`. Production resolution validates the sealed app bundle before considering any marker or environment override. Every staged file is compared byte-for-byte for migration integrity, but executable scanner/report/cleanup/watch paths always come from the signed bundle; the Application Support tree is never executable input. User settings remain separate at `~/Library/Application Support/PC Health Check/config.json` (mode `0600`); only `data/config.example.json` is tracked and bundled.

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

- `python3 -m pytest tests/ -q`: rule/report/runtime contracts and destructive-boundary tests in isolated fixtures.
- `swift test --package-path macos/PCHealthCheckMac`: native model, selection, history, presentation, and runtime-staging tests.
- `python3 scripts/release_smoke.py`: OS-specific source allowlists plus secret/PII/archive-structure audit.
- `scripts/package_macos_release.sh --local`: strict Universal 2 standalone app/DMG build under `dist/local/`, clearly unsigned for distribution and never overwriting a release artifact.
- `scripts/package_macos_release.sh`: clean exact-tag gate, source-prefix removal, architecture/minimum-OS validation, payload audit, Developer ID signing, hardened runtime, notarytool, stapling, Gatekeeper validation, and sidecar release metadata when credentials are supplied externally.
