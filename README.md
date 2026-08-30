# Modore

> **Modore audits durable local state that outlives the work, tool, or software that created it** — so you can see what still matters, what no longer has an owner, and what is safe to reclaim. Agent sessions whose workspace is gone, worktrees holding the only copy of unpushed work, trust roots installed by software you removed months ago, model caches nothing references: state that survived its creator, judged by provenance and survival — deterministically, metadata-only, with no LLM anywhere in the judgment path.
>
> Built for Macs shaped by AI-assisted development.

[🌐 **Website**](https://heznpc.github.io/modore/) · [📦 Releases (when published)](https://github.com/heznpc/modore/releases) · [Architecture](./docs/ARCHITECTURE.md)

*Part of the Heznpc portfolio — Trust tier (Supporting).*

> **Source-preview status:** no public installer is currently published. Review and build the source, or wait for a release whose DMG is Developer ID signed, notarized, stapled, Gatekeeper-assessed, and accompanied by SHA-256/build metadata.

---

## What it answers

Everything below is one question asked of different stores: **what survived, what still matters, and what can be reclaimed.** A session outlives its workspace; a worktree outlives its branch; a trust root outlives its installer; a model cache outlives the experiment. Each audit connects a survivor to its origin and judges whether it is protected, orphaned, or rebuildable — and none of them deletes anything.

### What your AI tools left behind (Mac)

On a Mac where Claude Code, Codex, Gemini, or an AI IDE has been working, the machine fills with traces nothing audits end to end: session stores that silently expire on rolling windows, agent git worktrees holding the only copy of unpushed work, orphaned sessions pointing at deleted projects, gigabytes of rebuildable model and editor caches, and paths whose only surviving record is a session transcript. **scree**, Modore's session-and-residue audit, judges all of it — deterministically, metadata-only, with no LLM anywhere in the judgment path:

```bash
python3 scripts/scree.py                          # join · retention forecast · orphans · sole-copy verdicts · lineage
python3 scripts/scree.py preserve <session-file>  # masked conversation text, not an original backup
python3 scripts/scree.py bind <workspace> --deep  # which AI sessions a delete would strand
python3 scripts/scree.py title <session-file>     # one masked line: what that session was about
```

- **Cross-tool join** — which tools touched which workspace/repository, when, across Claude Code, Codex, Gemini CLI, and VS Code-fork stores.
- **Retention forecast** — per-store rolling windows estimated from file ages, with D-day flags for sessions about to expire inside still-active projects. Deleting a conversation in the Claude desktop app rewrites only that app's index and leaves the transcript on disk, so those sessions are read from the desktop tombstones (filenames only), marked `owner_deleted`, and sorted below the rest: a transcript outliving the delete that was meant to remove it is not a reason to urge its rescue.
- **Sole-copy judgment** — agent worktrees *and* primary checkouts stranded off main: protected (dirty or unpushed commits) versus rebuildable, from read-only git evidence, every verdict preview-grade with an explicit revalidation duty.
- **Orphans & lineage** — sessions pointing at vanished workspaces (`orphan_basis: path_missing`), and every remembered work path classified alive+git / alive+plain / vanished, with macOS case-variant ghosts merged.
- **Not a uniqueness claim about the primitive** — an agent IDE that creates worktrees can and does compute the same unpushed-work verdict for the worktrees it manages (Orca's workspace cleanup runs the same `rev-list --not --remotes` check). scree's coverage is the difference: it sweeps every agent worktree on the machine regardless of which tool created it, plus primary checkouts stranded off main and registry entries whose directory is gone.
- **Contract** — ordinary audits retain only metadata; nested transcripts are attributed by `stat()` without being opened. Explicit `preserve`, `title`, `titles`, `inspect`, `search`, `evidence`, and `bind --deep` commands may read content as documented in `scree.py`. Raw backup operations below are a separate opt-in exception. None of these outputs grants deletion permission, and scans never create backups automatically.

### Currently implemented — Original session backups (Mac)

In **작업**, select a Claude or Codex conversation and choose **원본 백업…**.
The separate **대화 내보내기…** action still produces masked Markdown text;
it does not preserve structured tool calls or results.

- **Scope:** one transcript from the default Claude or Codex session store. Claude backups also include existing session-scoped `subagents/`, `tool-results/`, `file-history/`, `image-cache/`, and `uploads/` files. Codex backups contain the selected transcript only. Workspace code, shared project memory, settings/credential files, other sessions, and externally referenced files are excluded.
- **Integrity:** a ZIP with a versioned manifest, file sizes, and SHA-256 digests. Creation detects source changes, verifies the archive, and refuses to overwrite a destination. Limits are 10,000 files and 2 GiB of uncompressed data per session.
- **Restore:** **백업 확인·복원…** opens an existing backup even when its original session is gone. All entries are checked before extraction; restore creates a new directory and verifies the extracted bytes. Existing directories, unsafe archive paths, and symlink entries are rejected. Restore does not register or resume the session inside a provider app.
- **Privacy:** raw backups require acknowledgement. They are **not masked or encrypted** and can contain secrets already present in transcripts. ZIPs and restored files are owner-only (0600), restored directories 0700. No upload or model call occurs. Keep a separate protected copy off the source disk for disk-failure protection; do not publish raw backups in a public Git repository.

```bash
python3 scripts/scree.py backup <session-file> --out <new-backup.zip> --include-sensitive
python3 scripts/scree.py backup-verify <backup.zip>
python3 scripts/scree.py backup-restore <backup.zip> --out <new-directory>
```

**Design intent:** inspect what matters, preserve original evidence, and test
restoration before deciding how to manage local storage. **Non-goals:** automatic
deletion, full machine backup, provider migration, or a guarantee that a provider
can resume an archived session. A successful byte comparison is not a cleanup
authorization.

**friction**, scree's sibling, reads the same four session stores for the opposite question — not what the agents left behind, but where the operator stopped them:

```bash
python3 scripts/friction.py                                  # 9-category pushback taxonomy · severity 1-3
python3 scripts/friction.py scan --json --source codex       # structured output, one store
```

- **Nine categories** — wrong-action, no-research-assertion, stalling-approval, rule-contamination, over-orchestration-token, stale-repetition, verbosity, tone-attitude, other-ai-friction, at severity 1 (mild correction) / 2 (clear irritation) / 3 (rage). Taxonomy and severity ladder are cited from a 2026-07 human audit of 2,630 user turns yielding 515 findings; they are not re-derived here.
- **Four stores** — Claude Code and Codex are discovered through scree's own collectors; Gemini CLI chats and Claude Desktop local-agent sessions are added on top, joined to a real workspace path where the store records one.
- **Same judgment contract** — keyword and tone matching only, no model anywhere in the path; a review aid that both under- and over-catches, so every verdict is tagged `evidence: preview`.
- **Content contract** — only turns authored by the user are examined; assistant text, tool calls, and nested subagent transcripts are never emitted. Quotes are capped at 200 characters and masked (email / JWT / API keys / private keys / home path) by default, with `--raw-quotes` as the explicit opt-out. Nothing is written.

### What stayed after you uninstalled it

Removing an app does not remove what it registered. `moraine` reads the two records that outlive the uninstall — macOS installer receipts and the system/user trust stores — and correlates them:

```bash
python3 scripts/moraine.py            # receipts · trusted roots · orphaned-root verdict
python3 scripts/moraine.py --json
```

- **Receipts** — every package ever installed, with whether its payload still exists (`present` / `partial` / `vanished` / `no_payload`) and when it was installed. macOS never forgets a receipt, so it outlives the files.
- **Trusted roots** — every root in the admin and user trust domains, with self-signed / CA / key size / validity, and whether its trust is *unconditional*. An empty usage-constraint array means "trust as root for every policy", which reads like "nothing configured" and is exactly the opposite.
- **The correlated verdict** — a trusted root whose installing package has no payload left is a certificate still vouching for a vendor otherwise gone from the machine. Neither source produces that alone. `unattributed` means no receipt claims the root: MDM profiles, enterprise Wi-Fi, and hand-imported roots are legitimately unattributed, so it is a statement about attribution, not legitimacy.
- **Prior art** — AppCleaner is the reference for moraine hunting and its location list is genuinely vetted, but it is target-driven (you drop an app on it) and its binary contains no `SecTrust`/`SecCertificate` symbols at all; mole reads `pkgutil` receipts too, but only to locate app bundles in `/usr/local` and `/opt`, never to judge whether a payload survived. The trust store is the half neither reaches.
- **Deletes nothing.** Removing a trust root is an admin act and stays a human decision.

### Both questions, mid-session (MCP)

The judgments above were terminal-only, which meant the agent doing the work could not ask them while working. Modore ships a zero-dependency MCP server so it can — before deleting a worktree, before assuming a session will still be there tomorrow, before repeating something the operator already objected to:

```bash
python3 scripts/mcp_server.py --tools    # inspect the surface without speaking JSON-RPC at it
```

```json
{"mcpServers": {"modore": {"command": "python3", "args": ["<repo>/scripts/mcp_server.py"]}}}
```

- `agent_state_report` — the join, retention forecast, orphan/sole-copy/lineage judgment, by section, with every truncation reported.
- `agent_session_list` — newest-first local session metadata from `scree sessions`; conversation bodies are not opened.
- `agent_session_search` — an explicit user-requested phrase search delegated to `scree search`; the query stays off argv and returned snippets remain masked.
- `operator_friction_report` — the pushback taxonomy, filterable by store, category, and minimum severity.
- `model_residue_report` — which models in the Hugging Face hub cache no project file names, and how many gigabytes those account for. Reports `search_complete`; when the search could not be exhaustive every model is `unknown`, never `unreferenced`.
- `mcp_hygiene` — registered MCP servers that cannot start: dead command, missing script path, duplicate entry, or an `env` block worth a human look (reported as a key count, never as keys or values).
- `agent_file_access` — the reverse index: which sessions touched which paths, with reads/writes/shell counts. Agent rule surfaces first, because a silently edited `CLAUDE.md` is the case it exists for.
- `system_scan_summary` — the storage and security scan result *already on disk*, with its age in seconds and an explicit `stale` verdict by the app's own six-hour rule, because a stale result read as current is the failure mode here.
- `uninstall_residue_report` — installer receipts, trusted roots, and the orphaned-root verdict above.
- **A thin layer, not a second implementation** — each tool runs one judgment script with `--json` and forwards what it prints, so the CLI, the Mac app, and the MCP surface cannot disagree about what is true.
- **Read-only by contract, enforced at registration** — a tool is reachable only if it is on an explicit allowlist and annotated read-only and non-destructive; one added without a deliberate edit fails closed. Cleanup, deletion, and scan execution are deliberately absent. Modore gates destruction on an approval a human grants on screen; an agent-reachable bypass would not be a feature, it would be the end of that guarantee. Every result is fenced as untrusted data.
- **This surface can cross the local boundary — read-only is not the same as local-only.** The server itself speaks stdio and makes no network request or LLM API call, and no judgment here is produced by a model, exactly as everywhere else in Modore. But a tool result exists to be read by whatever client invoked it: local metadata, directory and process names, and (from `operator_friction_report`) masked, length-capped excerpts of turns you wrote become available to that client, and whether they then leave this machine depends on that client's and its model provider's data-handling policy — a wholly local client and model is a different answer than a hosted one. Two claims that sound alike and are not: *no model produces Modore's verdicts* is true on every surface; *nothing Modore reads reaches a model* is true of the app and script mode, and is not what connecting this server means. Several tools also read machine-wide session stores rather than only the current project, so register it per-project (`--scope local` in Claude Code) rather than globally until you want that breadth.

### Why is this machine busy? (maintained diagnostics)

A fan that will not stop, CPU/GPU load while idle, an unknown process, a strange network connection, disk space vanishing overnight. Generic scanners detect but do not explain — and on a Korean banking/government PC they cry wolf over IPinside, nProtect, MagicLine and the rest of the mandated plugin set until users either panic-uninstall critical software or learn to ignore every warning. Modore is the second opinion: it joins process, network, autorun, security, and storage signals, checks miner-like runtime patterns, recognizes the Korean plugin set with a locale-aware whitelist, and explains every finding in plain Korean, English, or Japanese with a 🟢🟡🔴 verdict. Nothing is ever deleted automatically.

This diagnostic surface is **maintained, not growing**: bug and security fixes continue, but new Modore capability lands on the durable-state side above. Live monitoring that does not contribute to provenance, residue attribution, or a bounded cleanup decision is out of scope.

---

## What ships today

- **Two OS editions under one brand**: Modore for Windows and Modore for Mac share the same promise — explain local machine state in plain language without deleting anything automatically.
- **Mac Edition — AI-agent session audit**: `scree` (above) is the flagship Mac capability — cross-tool join, retention forecast, orphan/sole-copy/lineage judgment, metadata-only.
- **Mac Edition — leave-behind audit**: `moraine` judges what survived an uninstall from installer receipts and the macOS trust store, including root certificates left trusted by software that is no longer installed.
- **Mac Edition — operator-friction scan**: `friction` classifies the turns where the operator pushed back on agent behaviour across Claude Code, Codex, Gemini CLI, and Claude Desktop transcripts — nine categories, severity 1-3, deterministic keyword/tone matching, user-authored turns only, quotes masked by default.
- **Mac Edition — Hugging Face cache audit**: `hfscan` cross-references every cached model against the code on this machine and reports which ones nothing names. An incomplete search withholds the verdict instead of guessing.
- **Mac Edition — MCP config hygiene**: `mcpaudit` reads the registered MCP servers and reports the entries that cannot start. It never edits a config, disables a server, or starts one.
- **Mac Edition — file-access reverse index**: `fileaccess` answers "which sessions touched this file, how often, and when last", rule surfaces first. Only paths and tool names are kept — the command a path came from is never emitted.
- **Read-only MCP surface**: a zero-dependency stdio MCP server exposing scree, friction, the two audits above, and the existing storage/security scan summary to an agent mid-session. Judgment only — no cleanup, no deletion, no scan execution.
- **Mac Edition scanner**: Bash + JXA collectors for macOS security context, launchd/login items, Gatekeeper/SIP/XProtect, network/listening ports, installed-app size, and developer-runtime incidents. Every collector reports `ok`, `permission_denied`, `unavailable`, `timed_out`, or `failed`; a missing required collector can never become a safe verdict.
- **Mac Edition app**: the native SwiftUI app presents one incident judgment followed by evidence, likely impact, and approval-gated recovery; bounded local history keeps the judgment without storing raw commands or URLs. Browser automation is grouped into roots with PID, parent, elapsed time, channel, profile type, and a privacy-preserving controller label.
- **Windows Edition**: PowerShell 5.1+ scanner focused on Korean banking/government plugin context, Windows Defender, Sysinternals-backed signature/autoruns coverage, networking, startup entries, scheduled tasks, recent installs, and the 5-minute idle CPU monitor.
- **Storage decoded, AI residue included**: rebuildable build residue inside dev projects (Flutter, node_modules, Cargo, SwiftPM, Pods, Gradle) with the official regeneration command instead of a delete button, plus a mapped AI-tool residue layer — Claude and Codex stores path by path, and Ollama model blobs, Kiro, VS Code, and Gemini CLI caches split into reclaimable versus protected.
- **Local recurrence watch**: an optional hourly LaunchAgent keeps a bounded owner-only free-space timeline. It notifies when free space falls below 20GB or drops by at least 8GB between checks; it never deletes anything.
- **Suspicion-to-evidence workflow**: CPU/GPU load, idle CPU samples, miner process names, miner-pool ports, network endpoints, autoruns, signatures, and optional VirusTotal hash lookups are shown together so a user can decide what deserves a closer look before removing anything.
- **Locale-aware whitelist**: 73 known-good entries across 7 categories (system, browser, korean_common, banking_security, dev_tools, hardware, cloud), plus 20 miner blacklist entries, 6 RAT blacklist entries, and 13 miner-pool ports. Covers IPinside, nProtect, INISAFE, MagicLine, Veraport, XecureWeb, Ahnlab V3, Alyac, and the rest of the Korean banking/government plugin set.
- **Traffic-light output** (🟢 safe / 🟡 check / 🔴 danger) so non-technical users can act on the report.
- **VirusTotal lookup (opt-in)**: SHA-256 hash query only. 48h local cache, 16s rate-limit, respects the public API quota (4 req/min, 500/day).
- **Single-file HTML report**: opens in the user's browser and works offline. The shipped OS-native reports include user-clicked Google/VirusTotal investigation links; opening one shares the selected search term, IP address, or hash with that site. The Python development report also includes collapsible novice-friendly explanations. On Mac, HTML is an export/share artifact; the SwiftUI utility interface is the primary experience.
- **Local-only by default**: the Mac SwiftUI app and script mode run local scanners only. There is no AI/LLM integration, no OpenAI/Claude/Codex API call, no token spend, no account login, and no report upload. Connecting the optional MCP server adds another data path: tool results become available to the client you registered it with, and whether they leave this machine then depends on that client's and its model provider's data-handling policy; see the MCP section above. The optional automatic VirusTotal API lookup is the only network request initiated by a Mac scan and sends file SHA-256 hashes only. Windows can separately download Microsoft Sysinternals tools only after the configured consent step.
- **i18n**: English is the source language everywhere. The Python development report keeps en/ko/ja strings (`data/report_i18n/`); the Korean whitelist/explanation depth is a specialized data layer, not the default voice.
- **Rule engine + tests**: declarative JSON rules in `rules/` (autoruns, defender, installs, network, process) evaluated by OS-native runtime engines. Pytest covers report/rule/cleanup/release contracts; Swift tests cover stable selection, protected data, storage accounting, cleanup protocol parsing, and standalone runtime staging.
- **Read-the-source distribution**: source release ZIPs contain readable PowerShell/Bash/JXA and Swift code, no bundled DLLs, and no telemetry. A separately produced Developer ID/notarized DMG may contain the compiled Mac app, but its scanner/rules remain bundled as readable resources and the source ZIP remains the audit surface.

## Planned

- **Mac Edition Swift app** — deepen project-manifest parsing for SDK/runtime version requirements and expand attributable app-residue mappings without weakening the local approval boundary.
- **Windows Edition maintenance** — Windows remains under the same Modore brand, but new Windows-only storage features wait for real-device validation.
- **Additional report locales** beyond en/ko/ja — community PRs welcome; the report i18n loader (`data/report_i18n/`) already supports arbitrary codes.

## Editions

Modore is the brand. The OS editions are separate products under that brand, not feature-parity promises.

| Edition | Artifact | Focus | Validation rule |
|---|---|---|---|
| Mac Edition | `modore-v0.3.x-mac-source.zip`, optional notarized Universal 2 DMG | The scree AI-agent session/residue audit, plus macOS security context and decoding of the System Data / Developer / macOS storage bar into real paths and safe next actions | Mac-only features ship after local macOS validation |
| Windows Edition | `modore-v0.3.x-win.zip` | Korean banking/government security-plugin context, Defender, Sysinternals, autoruns, network, idle CPU monitor | Windows-only features ship only after real Windows-device validation |

Shared rules, whitelist data, i18n strings, and report vocabulary can be reused where they genuinely match. OS-specific collectors stay separate.

## Scope

The boundary every new capability is judged against:

**In scope** — durable local state whose creator, owner, workspace, package, or original purpose may no longer be present or obvious, when Modore can establish useful provenance, survival, protection, or reclaimability evidence. Sessions, worktrees, uninstall residue, model and build caches, trust roots, agent environment registrations.

**Out of scope** — generic live system monitoring or threat detection that does not materially contribute to provenance, residue attribution, recovery, or a bounded cleanup decision. The existing diagnostic surface stays maintained; it does not grow.

"AI-builder Mac" is the audience this is built for, not a filter on what qualifies: an orphaned trust root from a removed banking plugin and an orphaned worktree from a removed agent workspace are the same problem, and both are in.

## Design intent

**Windows stays scripts + HTML; Mac uses a native utility interface over the same readable runtime.** This is the load-bearing choice:

| Concern | Windows Edition | Mac Edition |
|---|---|---|
| Primary UI | PowerShell launcher + offline HTML | Native SwiftUI app + offline HTML export |
| Runtime truth | Readable PowerShell and JSON rules | Readable Bash/JXA, JSON rules, and Swift source |
| Distribution | Source ZIP | Source ZIP; optional Developer ID/notarized standalone DMG |
| Network default | Local, except opt-in hash lookup/downloads | Local, except opt-in VirusTotal hash lookup |

The Mac app bundles only the allowlisted Bash/JXA/data/rule runtime it needs. A standalone build validates the app's sealed code-signature resources, captures every interpreter input between signature checks, and executes those bytes through anonymous file descriptors. Owner-controlled Application Support is used only for the non-executable runtime mirror, migration state, local configuration, and a separate `results/` directory; app updates do not replace scan results or reports. It never executes the replaceable Application Support mirror and never depends on the developer's checkout path. User settings stay at `~/Library/Application Support/Modore/config.json`; the tracked `data/config.example.json` contains no key.

**Deterministic, metadata-only judgment is the product.** Every verdict — the traffic-light scan result and the scree session/residue judgment alike — comes from declarative rules and read-only metadata, never from a generative model. The same input always produces the same output, the full judgment path is readable source, and adversarial data (a process name, a session file) cannot talk a probabilistic judge into a false verdict.

**Cleanup is local and approval-gated.** Modore remains the pause before deletion, but the Mac Edition can execute audited recipes for rebuildable caches, Claude VM bundles, Xcode DerivedData, stale Chrome clones, and the known INNORIX user module. Installed apps are re-resolved by bundle ID and moved with exactly attributable containers/caches/preferences to a per-run Trash folder; Xcode and app bundles containing developer SDK/toolchain payloads are blocked. Individual Shutdown Simulator devices can be removed by a normalized UUID revalidated through `simctl`; Booted devices and locally preserved UUIDs are checked again immediately before deletion. Preview produces a short-lived approval manifest binding canonical paths, tree size, process state, and filesystem identity; execution remeasures before and after the same-volume staged move. Normal app termination waits for an approved destructive transaction to reach its receipt boundary instead of abandoning a child process. SDKs, Simulator runtimes, Codex session JSONL, Claude local-agent workspaces, and Codex databases have no cleanup recipe.

**The incident comes before cleanup.** The Mac home screen is ordered as judgment → observed evidence → likely impact → recovery. A browser or developer-runtime process is never killed merely because it is old or large. A detached, long-running automation tree is labeled as a residue candidate, and the app preserves the local incident summary so a later scan can show what was observed at that time.

**Privacy-first VirusTotal use.** Hashes only, never file contents. VirusTotal calls live in `scripts/vt-lookup.ps1` and `scripts/scanner_helper.jxa.js`; optional Sysinternals downloads live in `scripts/sigcheck-helper.ps1` and `scripts/autorunsc-helper.ps1`. Grep for `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api` to audit outbound calls.

**Mac local-only UX.** The SwiftUI Mac frontend shows whether VirusTotal is enabled, labels the normal state as local-only, opens the user-owned Application Support config, and explains Full Disk Access when macOS privacy settings hide Mail, Messages, Safari, or app-container data. Status, storage, security, activity, and settings use native navigation and lists. Cleanup is never automatic: each supported row opens a scrollable preview with remeasured targets, process blockers, and rebuild cost before the user can approve it. The development workspace also reports browser-automation roots with PID, profile, elapsed time, controller clues, and estimated descendant RSS. An isolated browser or disposable temporary Chrome profile can receive an explicitly approved `SIGTERM` only after the PID, start time, real executable path, and command identity are revalidated; the normal default profile and persistent custom profiles are never eligible, and the app does not escalate to `SIGKILL`.

**Mac storage scan speed.** The SwiftUI quick scan caps each expensive `du` measurement so huge Simulator or SDK directories do not make the app feel stuck. Timed-out rows are shown as "measurement deferred" instead of a fake size. For an exact CLI pass, run `PCH_STORAGE_DU_TIMEOUT=0 bash scripts/scanner.sh`.

## Non-goals

- **Not a replacement for antivirus.** Keep using Windows Defender, V3 Lite, Malwarebytes, etc. Recommended workflow:
  1. **Windows Defender** (or V3 Lite / Alyac) for real-time baseline protection.
  2. **Malwarebytes Free** or **Emsisoft Emergency Kit** for deep scans when suspicious.
  3. **This tool** to understand *what's actually running* and whether your banking plugins are normal.
- **Not a cryptominer remover.** It detects patterns and alerts you; removal is left to the user's AV.
- **Not real-time protection.** It's an on-demand scan that produces an HTML report.
- **Not a Korean-only tool.** English is the source language and the AI-agent session audit is locale-agnostic; the banking/government plugin whitelist is a Korean-specialized data layer, not the whole product.

## Redacted

- Specific external persons who contributed feedback or testing context are intentionally not named in this README.
- Any user-PC scan artifacts (`scan_result.json`, `monitor_result.json`, `raw_facts.json`, `검사결과*.html`, `vt-cache.json`) are gitignored — they contain PC-identifying data and must not be committed.

---

## Installation

### macOS
1. No public DMG is currently published. Clone the source, then right-click `run-mac-app.command` → **Open**. It builds and opens `build/macos/Modore.app`.
2. When a release includes a notarized Universal 2 DMG, verify its SHA-256 metadata, open it, and drag **Modore** to Applications. No Swift toolchain is required for that artifact.
3. For script-only mode, right-click `scan.command` → **Open**.
4. Follow the menu or the SwiftUI app controls. Cleanup always requires an item preview and a second explicit approval.

### Windows
1. While the repository is in source-preview status, clone it or use GitHub's source archive.
2. Once a verified release exists, prefer its `modore-v*-win.zip` and compare the published SHA-256 metadata.
3. Extract anywhere (USB, Desktop, Downloads — no installer needed), then double-click `scan.bat`.

### Requirements
- **macOS script mode**: Bash + `osascript` (built into macOS).
- **macOS SwiftUI source mode**: macOS 13 or later plus Swift tools 5.9 or later from the system-selected, root-owned Xcode under `/Applications` or Command Line Tools under `/Library/Developer/CommandLineTools`. The explicitly nonpublishable local/CI packaging check may also use an ephemeral current-user-owned Xcode when it is not group/world writable; public distribution never receives that exception. A notarized DMG does not require the toolchain.
- **Windows**: PowerShell 5.1+ (built into Windows 10/11).
- **Development / tests only**: Python 3.11+ for pytest, release-smoke packaging, and local docs preview.

### Troubleshooting

- **The precise Windows scan needs 5 quiet minutes.** It includes an idle-CPU observation window; close video/game workloads and let the machine sit idle so it can catch "using CPU while doing nothing" processes.
- **"This script cannot be run on this system" (Windows).** Open PowerShell as the current user and run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- **A console window flashes and closes immediately (`scan.bat`).** Right-click → "Run as administrator".
- **macOS "developer cannot be verified" warning.** Right-click the file → **Open** (only needed once).
- **Fully portable.** Copy the whole `modore/` folder to a USB drive and run it from any Windows or Mac machine — no installer.
- **Not an antivirus replacement.** Pair Windows Defender / macOS Gatekeeper (built in) with Malwarebytes Free for a second opinion when something looks wrong.

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
   `VT_API_KEY` supplies the secret without writing it into the project, but network lookup still requires `virustotal.enabled` to be `true` in the local user config. The macOS/Linux `export` and current-session PowerShell forms are process-session values and are not written by Modore. The persistent Windows form is stored in the current user's registry hive on disk; use it only on a trusted single-user account and remove it when no longer needed.

   **Option B — ignored user config:** the SwiftUI Mac app, including builds opened through `run-mac-app.command`, uses `~/Library/Application Support/Modore/config.json`. Script-only source/archive mode may copy `data/config.example.json` to the ignored `data/config.json`. Windows can also use `%LOCALAPPDATA%\Modore\config.json`.
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
   chmod 600 "$HOME/Library/Application Support/Modore/config.json"

   # Windows (PowerShell, owner-only ACL)
   icacls data\config.json /inheritance:r /grant:r "$env:USERNAME:F"
   icacls "$env:LOCALAPPDATA\Modore\config.json" /inheritance:r /grant:r "$env:USERNAME:F"
   ```

4. Run the scan. File hashes will be cross-checked against 70+ antivirus engines.

**Privacy note.** Only the SHA-256 hash is sent. VirusTotal never receives file contents. If the hash is unknown, the tool reports "unknown" — it does not upload the file.

## Project structure

```
modore/
├── scan.bat                  Windows launcher (double-click)
├── scan.command              macOS launcher (double-click)
├── run-mac-app.command       macOS SwiftUI app builder/launcher
├── README.md                 This file
├── docs/
│   ├── index.html            GitHub Pages landing (static, English)
│   └── style.css
├── data/
│   ├── whitelist.json        Korean programs + miner blacklist DB
│   ├── explain.json          Plain-language explanations per check
│   ├── config.example.json   tracked safe defaults; copy to ignored config.json locally
│   └── report_i18n/          en / ko / ja Python development report strings
├── rules/                    Declarative rule JSON
│   ├── autoruns.json
│   ├── defender.json
│   ├── installs.json
│   ├── network.json
│   └── process.json
├── scripts/
│   ├── scree.py              AI-agent session & residue audit (metadata-only)
│   ├── friction.py           operator-pushback scan over the same session stores
│   ├── moraine.py            receipts + trust-store audit of what survived an uninstall
│   ├── hfscan.py             Hugging Face hub cache: which models nothing here names
│   ├── mcpaudit.py           MCP config hygiene: registered servers that cannot start
│   ├── fileaccess.py         reverse index: which sessions touched which paths
│   ├── mcp_server.py         read-only MCP surface (scree · friction · moraine · hfscan · mcpaudit · fileaccess · scan summary)
│   ├── menu.ps1              Windows interactive menu
│   ├── scanner.ps1           Windows scanner
│   ├── monitor.ps1           Windows 5-min idle monitor
│   ├── idle_cpu.sh           Mac idle CPU observer with ancestor attribution
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
│   └── Modore/     SwiftUI app, feature views, models, and Swift tests
└── tests/                    pytest service and safety contracts
```

## Landing page

The `docs/` folder is the project landing page, designed for GitHub Pages. It is a static, script-free English page: two HTML/CSS files, no client-side i18n runtime.

To serve locally:
```bash
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```

## Tests

```bash
python3 -I -B -m pytest tests/ -q
swift test --package-path macos/Modore \
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
PCH_NOTARY_PROFILE="modore-notary" \
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
| SpecStory | Win/Mac | AI coding users | Saves and searches AI coding sessions | scree does not archive content; it judges retention risk, orphans, and sole-copy work, metadata-only |
| Agent Sessions | Mac | Claude Code / Codex users | Browses local session logs | scree adds the cross-tool join, expiry forecast, and worktree/checkout/lineage verdicts |
| Malwarebytes Free | Win/Mac | General users | Real detection | This = context. Use both. |
| Windows Defender | Win | Everyone | Real-time protection | Complementary |
| Sysinternals Autoruns | Win | Experts | Exhaustive autoruns | We wrap it and explain in plain language |
| Objective-See tools | Mac | Prosumer+ | Native UX | English only, fragmented across many tools |
| Hoax Eliminator / 구라제거기 | Win | Korean users | Removes unwanted Korean banking/security modules | This explains which entries are normal, noisy, or suspicious before removal |
| AppCleaner | Mac | Mac users | Removes an app and related files | This adds system/developer context and bundle-ID-verified Trash moves; AppCleaner may still discover app-name-based residue that cannot be attributed safely |
| Malware Zero (malzero.xyz) | Win | Korean users | PUP removal | Older UX, no per-finding explanations |
| HijackThis / FRST | Win | Tech-savvy | Log analysis | Not novice-friendly |

**The gap this fills**: on a Mac, a deterministic, metadata-only answer to "what did my AI agents leave behind?" — plus suspicion-to-evidence triage for "why is my PC this busy?", with plain-language explanations, locale-aware banking-software context, miner/runtime signals, storage context, and privacy-safe VT lookup.

## Privacy

- **No telemetry.** The tool never sends usage analytics or error reports.
- **No file uploads.** VirusTotal integration uses SHA-256 hashes only.
- **Local cache only.** VT response cache lives in `%LOCALAPPDATA%/PC건강검진/` (Windows) or `~/Library/Caches/PC건강검진/` (macOS).
- **Local cleanup receipts.** Mac cleanup receipts stay under `~/Library/Application Support/Modore/cleanup-receipts/`; they contain local paths and are never uploaded.
- **Local maintenance state.** Simulator keep UUIDs, bounded scan snapshots, and hourly free-space samples stay under `~/Library/Application Support/Modore/` with owner-only permissions. They are never uploaded and can contain local paths, so exported support material should not include them.
- **Auditable.** VirusTotal calls are in `scripts/vt-lookup.ps1` / `scripts/scanner_helper.jxa.js`; optional Sysinternals downloads are in `scripts/sigcheck-helper.ps1` / `scripts/autorunsc-helper.ps1`. Grep for `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api`.

## Contributing

Whitelist contributions are especially welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the full guide. Short version — if you recognize a legitimate local app missing from `data/whitelist.json`, open a PR with:
- Process name (lowercased, without extension)
- Vendor
- Short English/Korean/Japanese description
- Category (system / browser / korean_common / banking_security / dev_tools / hardware / cloud)

## Security

Vulnerability reports should go through GitHub's [Private Vulnerability Reporting](https://github.com/heznpc/modore/security/advisories/new). Do not place vulnerability details in a public issue; see [`SECURITY.md`](./SECURITY.md) for the full policy, scope, and response timeline.

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
