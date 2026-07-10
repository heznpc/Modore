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

The SwiftUI app owns navigation, local state presentation, approval sheets, and process execution. It does not duplicate scanner or cleanup policy in Swift.

Source builds use `project-root.txt` to run the checked-out scripts. Standalone builds omit that marker, embed an explicit runtime allowlist under `Contents/Resources/runtime`, and stage it to `~/Library/Application Support/PC Health Check/runtime`. Before reuse, every immutable staged file is compared byte-for-byte with the app bundle; a changed, missing, or symlinked file forces a refresh. Runtime refresh preserves only the existing local `data/config.json`.

## Mac source layout

- `Models/`: scan DTOs, history/delta models, stable selection keys.
- `Services/`: scanner process orchestration and standalone runtime staging.
- `Views/`: app shell and one file per user-facing destination.
- `Support/`: small presentation and process-safety helpers.
- `Tests/`: pure state, parsing, accounting, and runtime-install tests.

## Cleanup invariants

- No caller-supplied deletion path.
- No cleanup recipe for SDKs, Simulator runtimes, Codex session JSONL, Claude local-agent workspaces, or Codex log databases.
- App removal re-resolves a validated bundle ID instead of trusting a path from scan output.
- Simulator deletion revalidates the UUID with `simctl`; Booted and owner-preserved names are blocked.
- Symlinked or non-canonical targets are rejected.
- Preview is read-only; execute requires `--owner-approved`.
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
- `python3 scripts/release_smoke.py`: explicit OS-specific source ZIP allowlists.
- `scripts/package_macos_release.sh --local`: standalone app/DMG smoke without distribution trust claims.
- `scripts/package_macos_release.sh`: Developer ID signing, hardened runtime, notarytool, stapling, and Gatekeeper validation when credentials are supplied externally.
