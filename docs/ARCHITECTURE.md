# Architecture

Modore is an evidence-first local diagnostic tool with two OS-specific runtimes under one product promise. It does not attempt to hide the collectors behind a shared cross-platform abstraction when the operating systems expose different evidence.

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

Every app build embeds an explicit runtime allowlist under `Contents/Resources/runtime`; no build records the developer checkout path. The signed Mac app also carries a pinned python-build-standalone CPython runtime under `Contents/Resources/modore-python`, reduced to the interpreter and standard library needed by scree. Keeping the complete runtime in Resources prevents ordinary provenance and standard-library files from being misclassified as nested code under `Contents/Helpers`; the Mach-O interpreter itself is still signed before the enclosing app. The build verifies the upstream archive SHA-256, architecture and deployment target; artifact audit requires an exact per-file hash manifest and fixed provenance record. Scree runs that interpreter with `-I -B`; a signed app never falls back to PATH or a separately installed Python. Mutable output stays under `~/Library/Application Support/Modore/results`, separate from the non-executable runtime migration mirror. Production resolution validates the sealed app bundle, binds its active-slice cdhash to the kernel-tracked running process, captures every Bash/JXA/module/rule input, and validates the signature again. The process runner copies those captured bytes into unlinked files and passes only inherited `/dev/fd` handles to interpreters, so later bundle pathname replacement cannot change scanner, report, cleanup, or scheduler bytes. Child processes also start from a fixed minimal environment and pin the runtime working-directory device/inode. User settings remain separate at `~/Library/Application Support/Modore/config.json` (mode `0600`); only `data/config.example.json` is tracked and bundled. Legacy results are copied without overwrite, and unknown files in an old runtime are retained in a `runtime-backup-*` directory instead of being deleted. The hourly watcher uses an exact clean-environment LaunchAgent definition; both its on-disk plist and launchd's loaded program/arguments are revalidated, and unstable DMG/App Translocation paths are rejected. The source launcher asks an existing development app to terminate safely before rebuilding, so an old process cannot be paired with new resources.

## Mac source layout

- `Models/`: scan DTOs, one published content snapshot, storage/history models, and stable selection keys.
- `Services/`: process runner, scan pipeline, view-model orchestration, and standalone runtime staging.
- `Views/`: app shell, native destination lists/forms, storage workspaces, approval sheets, and shared setting components.
- `Support/`: bounded scan-log state plus small presentation and process-safety helpers.
- `Tests/`: pure state, parsing, accounting, and runtime-install tests.

## Session & residue audit (scree)

- `scripts/scree.py` is a deterministic, stdlib-only CLI module beside the scanner: it joins local
  AI-agent traces (Claude Code, Claude Desktop Code conversation units, Codex, Gemini CLI, VS Code forks) by workspace/repository, estimates
  per-store rolling retention windows, flags sessions near expiry inside still-living workspaces,
  marks orphaned workspaces with an explicit `orphan_basis`, and judges agent git worktrees
  protected-versus-rebuildable from read-only registry/push state.
- Contract: leading JSONL lines are decoded in memory but message content is never retained or
  emitted. Claude Desktop listing reads only a bounded metadata whitelist and treats one
  `local_*.json` plus its same-stem directory as one conversation; nested and sidecar transcripts
  are attributed by descriptor-bound `stat()` without being emitted. Every
  verdict is `evidence: preview` with a `requires_revalidation` duty for destructive consumers.
- Deliberate user-triggered exceptions are masked single-session inspect/search/export and deep
  binding. Raw backup is a separate opt-in path: it stores one named Claude Code/Codex transcript
  or one complete Claude Desktop conversation unit in a versioned ZIP with per-file SHA-256,
  verifies it, and restores only into a new directory. It never registers the result with a
  provider, follows selected workspace folders, or authorizes cleanup.

The native **Work** page is the composition boundary: Swift groups scree sessions, Mothball's
read-only repository assessment, and discovered worktrees by canonical workspace. Mothball's
archive/trash API remains unreachable without Modore's approval-token boundary. QuotaPie remains
a separate producer: Modore optionally reads only its owner-controlled semantic-v2
`~/Library/Application Support/QuotaPie/quota.json`; it does not share collectors, credentials,
network behavior, or process lifecycle.

Work passes Mothball only the exact repository roots already established by scree; it never falls
back to recursive discovery when a root disappears. The assessment has one 30-second screen budget,
a five-second/100,000-working-file measurement bound per repository, and path-specific incomplete
results. Git, `du`, and `find` are spawned from `/private/tmp` before the repository path reaches the
child through `git -C` or argv, keeping slow external-volume access inside cancellable process groups.
The optional QuotaPie file uses the same bounded no-follow open for existence and reading, so a
symlinked or malformed producer boundary is shown as invalid rather than followed.

Every scree invocation also reclaims scratch files left by a force quit only after one hour and
only when an exact generated prefix/UUID/extension, current owner, regular single-link type,
private results directory, and path/descriptor identities all still match. Restore output is
create-only and must remain outside every live Claude Code, Codex, and Claude Desktop session
store, including case variants and resolved symlink aliases.

## Absorbed audits (hfscan, mcpaudit, fileaccess)

- `scripts/hfscan.py` judges the Hugging Face hub cache: it derives each cached model's identifier
  from its hub directory name and searches the given roots for any occurrence. Absorbed from
  decant's `ContextProbe.swift` with that module's central defect inverted — an incomplete search
  (missing root, file cap reached, unreadable subtree) reports every model `unknown`, never
  `unreferenced`. Absence of evidence counts only when the search actually ran; the escape hatches
  are explicit flags, never a side effect of a mistyped argument.
- `scripts/mcpaudit.py` judges MCP configuration: which registered servers cannot start. Absorbed
  from decant's `MCPHygiene.swift`. `env` is reported as a key count only, and any verdict that
  depends on PATH is withheld when PATH is unusable — the same fail-safe rule as above.
- `scripts/fileaccess.py` inverts scree's evidence to path → sessions: reads, writes, shell
  references, session count, and last touch, with agent rule surfaces sorted first. Absorbed from
  canary's `get_file_access`. Its content contract is *stricter* than the original's — canary
  attached a 200-character excerpt of the shell command to every row, and that excerpt is command
  content, so it is dropped. A path extracted from a command is metadata about which file was
  touched; the command that touched it is not. Nested subagent transcripts stay unopened, matching
  scree's collector.
- All three are metadata-only, write nothing, and start nothing. None ships inside the signed app
  bundle: they have no Swift caller, so they stay CLI-and-MCP surfaces, and a test pins that
  giving one a view means moving it into `RUNTIME_FILES`.

## Cleanup invariants

- No caller-supplied deletion path.
- No cleanup recipe for SDKs, Simulator runtimes, Codex session JSONL, Claude local-agent workspaces, or Codex log databases.
- App removal re-resolves a validated bundle ID instead of trusting a path from scan output.
- Simulator deletion normalizes and revalidates the UUID with `simctl`; Booted, legacy, and owner-preserved UUID states are checked again at the destructive boundary.
- Preview records a 15-minute, owner-only manifest containing canonical paths, measured tree size, process fingerprint, and filesystem identity. Execute requires `--owner-approved` plus its one-time 256-bit token and remeasures immediately before and after the same-volume move.
- Child commands are spawned into a private process group and have bounded output/termination handling. Normal Cmd-Q termination is delayed while an approved destructive transaction is active so cleanup cannot become an unsupervised child.
- Directory traversal uses no-follow, descriptor-relative operations; symlinked or non-canonical targets are rejected at use time.
- A local receipt is written after execution.
- Project-residue process checks bound each cwd probe to about 2 seconds and stop starting probes after an 8-second pass budget (at most 64 candidates). An unknown cwd or exhausted budget blocks cleanup and is labeled as unverified, not as proven active use. Verdict and displayed evidence share one preview snapshot; approval-manifest and execution checks remain fresh.
- Preview diagnostics expose only allowlisted stage names, elapsed time and process termination metadata. Raw protocol output (including approval tokens) is not copied into logs. A failed, truncated, wrong-operation or wrong-recipe response cannot become an executable preview.

### Recovery accounting

- A recovery goal is the user's additional byte amount, not a hard-coded final free-space threshold. Approval takes a fresh volume reading and sets the final target to baseline plus that amount. The 20 GiB recommendation remains separate; retry after execution targets the remaining distance to the approved endpoint.
- Recovery arithmetic uses checked `Int64` bytes. Legacy scanner GiB estimates and `df`/`du` KiB readings convert at their boundaries; the recovery UI names binary units explicitly.
- Cleanup protocol version 1 gains additive `accountingVersion=2` and `estimatedBytes`, `reclaimedBytes`, and `physicalDeltaBytes` fields. Receipts also retain before/after available bytes. Legacy KB fields remain for older readers.
- Target occupancy reduction and whole-volume available-space net change are separate measurements. Volume changes remain signed, including decreases and measured zero; missing, malformed, or overflowing measurements are unknown. Unknown target occupancy never substitutes volume change.
- Byte fields are authoritative for accounting version 2. Older receipts convert KiB, but their clamped zero volume delta is unknown because the old writer conflated zero, decrease, and measurement failure. A missing final volume reading cannot prove goal attainment, even if an earlier reading succeeded.
- Plan-level history is stored separately from the old storage snapshots; it does not alter token expiry, target revalidation, or process-draining boundaries.

### Recovery plan history

- `RecoveryHistory` is a display-only record of one plan ID: byte goal and baseline, previewed paths and eligibility, approval time, per-item outcomes and receipt paths, final volume reading, and interruption state. Approval tokens are never serialized, and records cannot reconstruct executable plans.
- `recovery-history.json` lives in the private results root. `RecoveryHistoryStore` uses bounded owner-checked no-follow reads and atomic file/directory-synced writes. Unsupported or corrupt files are not overwritten. The first version caps storage at 200 plans / 8 MiB and refuses new writes at capacity instead of silently deleting history.
- Review, approval, before-item and after-item checkpoints are durable. Approval or pre-item write failure prevents execution; a failed result checkpoint prevents the next item. Cancellation/termination records whatever outcome is known, and the existing mutation marker still governs rescanning.
- On restart, approved/running records without a final checkpoint are shown as interrupted with unconfirmed results. Completed item records remain visible, but unrecorded receipts are not guessed or joined automatically. No historical plan is automatically resumed or re-approved.
- The Activity page presents the journal independently of scan snapshots. Existing receipts remain readable without inventing retroactive plan associations.

## Good contribution areas

The [Project / Asset Model v1 proposal](PROJECT_ASSET_MODEL_V1.md) defines the next
identity/evidence contract, producer boundaries and staged migration. It is design intent
for review, not an implemented common model. Its contract separates collection outcomes,
positive evidence with explicit provenance references, and assessments. The first migration
must produce evidence from a real Work input while preserving the existing UI identity;
the execution boundaries above remain authoritative.

- Verified Korean/Japanese application whitelist entries.
- False-positive fixtures that contain no personal scan data.
- New declarative rules with negative tests.
- macOS path attribution that can be proven from bundle IDs or documented tool layouts.
- Translations that preserve the same risk meaning.
- UI accessibility and keyboard-flow improvements that do not weaken approval boundaries.

Changes to outbound networking, signature verification, cleanup targets, standalone runtime staging, or protected-data rules require design discussion and dedicated negative tests.

## Verification map

- `python3 -I -B -m pytest tests/ -q`: rule/report/runtime contracts and destructive-boundary tests in isolated fixtures — including `tests/test_scree.py`, which pins scree's no-content-leak, masking, and single-session-export contracts, and `tests/test_hfscan.py`, which pins that every way a reference search can fail yields a withheld verdict rather than a false orphan.
- `swift test --package-path macos/Modore -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`: native model, selection, history, presentation, and runtime-staging tests under the CI compiler policy.
- `python3 -I -B scripts/release_smoke.py`: OS-specific source allowlists plus secret/PII/archive-structure audit.
- `scripts/package_macos_release.sh --local`: strict Universal 2 standalone app/DMG build under `dist/local/`, clearly unsigned for distribution and never overwriting a release artifact. Git, Swift/Xcode, Python audit, signing, and disk-image tools run from a minimal environment; metadata records the selected developer directory and Swift version.
- `scripts/package_macos_release.sh`: clean exact signed-annotated-tag gate pinned to an externally supplied SSH public-key fingerprint and principal `heznpc`, Git replace-object rejection, source-prefix removal, architecture/minimum-OS validation, payload audit, externally pinned Developer ID Team ID and leaf-certificate SHA-256, hardened runtime, notarytool, stapling, Gatekeeper validation, final source revalidation, and sidecar release metadata when credentials are supplied externally.
