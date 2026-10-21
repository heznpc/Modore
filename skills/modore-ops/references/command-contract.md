# Modore command contract

## Session continuity

```bash
modore sessions current
modore sessions --limit 50
modore inspect <source> --start 0 --turns 12
modore search --provider claude --workspace Modore --offset 0 --limit 20
modore search --first                         # query bytes arrive on stdin
modore search --limit 20 --budget-seconds 30  # query bytes arrive on stdin
modore search --cursor <nextCursor> --limit 20 # same query and filters on the next call
```

`sessions current` is the narrow first choice for the calling Codex task. It
uses `CODEX_THREAD_ID`/`CODEX_SESSION_ID` only as lookup hints, validates the
matching JSONL header, and reads no conversation body. `sessions` reads
metadata only and groups Codex rollout fragments by provider session ID while
retaining their physical sources. `search --first` returns the newest hit and
explicitly reports incomplete coverage. Ordinary `search` is the exhaustive
content-reading path;
snippets remain masked unless a user separately invokes lower-level raw mode.
The agent CLI defaults session listing to 50 and caps it at 500; search is
capped per page at 200 matches, a 55-second internal budget, a 60-second outer wall
clock, and a 4096-byte UTF-8 query. Larger positive match/time requests are reduced
to those per-page bounds with a stderr notice instead of rejecting the search.
Session listing has a 30-second outer wall
clock. Do not put the search phrase in shell history, process arguments, or a
temporary file.

Search filters apply before content reads: repeatable `--workspace` uses case-insensitive
substring matching (OR); `--workspace-exact` uses exact paths; repeatable
`--exclude-workspace` excludes matching paths. `--provider` selects claude/claude-desktop/codex/gemini/kiro.
Ordinary agent CLI and MCP searches return `nextCursor`. Repeat the same query and
filters with that cursor to continue at the unfinished artifact/hit. Completed
session bodies are not read again; metadata discovery still runs on each page.
Cursor pages use stable session identity order, rather
than the browser's newest-first order; merge pages by `matchId` because overlapping
rollout fragments may replay the same event. Tokens contain only hashes and counters;
no search phrase, transcript, path, or token file is retained. MCP accepts `provider`,
`workspace` (array), `workspace_exact`, `exclude_workspace` (array), and `cursor`.
MCP reports the requested/effective page bounds (200 matches / 60 seconds maximum).

Coverage and error counters accumulate across cursor pages. `scanFinished` means the
inventory was traversed; only `coverage: complete` establishes a complete search.
`progressMade: false` means the unfinished file or discovery could not finish within
this budget: increase the budget with the same cursor, or start a fresh search with
narrower filters, instead of repeating unchanged calls. A new/removed session or a changed unfinished session invalidates the cursor
with an explicit restart error. Already completed live sessions may grow without
resetting progress; run a fresh search to include their later additions.

Legacy `--offset`/`--first` remain available separately and cannot be combined with
a continuation cursor. `nextOffset` advances a legacy result page;
`hasMore: null` means its remaining coverage is unknown. Offsets are stable only
while the session store is unchanged. JSONL reads accept up to
512 MiB per file and 16 MiB per record; larger records/files still report truncation. Each file returns at most 2,000 hits;
that limit is also reported as incomplete coverage, not a complete search.

Backup, verification and restore remain available through
the Modore app and `scripts/scree.py`. Those operations require an exact named
source or archive; do not infer one from a transcript.

## Storage

```bash
modore storage status
modore cleanup list
modore storage recovery
```

`status` samples free space and the bounded drop evidence. `cleanup list` only
names fixed recipes; it does not create an approval token. `storage recovery`
opens the native Modore recovery plan with no target, tier, approval, or
execution flag; the app remeasures and asks the user before it changes data.
The agent command intentionally has no full-system scan or cleanup-preview
route: the former would collect unrelated security metadata, while the latter
would mint a live destructive approval token.

## Turn test resources

```bash
modore resources install-hooks --provider claude
modore resources install-hooks --provider codex
modore resources diagnose-hooks --project <path>
modore resources bind --id <UDID> --fingerprint <hash> --provider <provider> --session <ID> --project <path>
modore resources unbind --id <UDID> --provider <provider> --session <ID> --project <path>
modore resources begin-test --runtime <runtime> --provider <provider> --session <ID> --project <path> --turn <token>
modore resources begin-browser-test --provider <provider> --session <ID> --project <path> --turn <token> --url <URL> [--headed]
modore resources hold --id <UDID> --provider <provider> --session <ID> --turn <token>
modore resources release --id <UDID> --provider <provider> --session <ID>
```

The installer merges two synchronous lifecycle hooks, a resource-policy
`PreToolUse` guard for all tools, and a Vercel CLI reuse guard into the selected user's
configuration and backs up existing JSON under Modore's work-resource directory.
It preserves other hooks and does not grant trust. Codex requires review of the
four hooks in `/hooks`; existing sessions may need a refresh. `diagnose-hooks`
reads the installed Codex runtime's enabled/trust states, without granting trust.
Bindings persist independently of leases. A stale or busy assigned simulator
blocks selection instead of falling back to another target. The UI and CLI use
raw provider session IDs, not prefixed session-list row IDs.

`UserPromptSubmit` records metadata and supplies the turn token. `Stop` explicitly
ends that turn's managed test use. Codex matches `turn_id`; Claude uses a generated
token and synchronous prompt/Stop ordering. The bridge ignores other lifecycle
events and never reads a transcript or stores prompt/response/tool contents.
It never emits a decision to interrupt, end, or continue an AI session.

`begin-test` only boots an existing Shutdown simulator with no unresolved lease.
Shutdown requires the same UDID, resource fingerprint, and boot timestamp, and
no unreleased consumer, including expired registrations. `hold` keeps a preview
or background test running until explicit `release`. Foreign and unregistered
running devices are never adopted. Boot intent and status remain in the registry;
shutdown writes a receipt with the verification result. An uncertain boot or
changed identity prevents automatic shutdown.
Command timeout or a missing/disabled hook leaves a pending resource for review;
it is not proof of successful cleanup. This feature covers managed simulator
and Playwright CLI browser runs, not arbitrary processes or AI sessions. Hook `Stop` can
also be an attempted turn finish followed by another hook's continuation; the
next simulator use must call `begin-test` again.

`begin-browser-test` starts one randomly named Playwright session per turn using
locally installed Node and `@playwright/cli` (optional `--node`/`--cli` absolute
paths). Its private workspace fixes the browser to bundled Chromium, preventing
project configuration from selecting ordinary Chrome, a user profile, or CDP.
No package or browser installation runs in a hook. Repeated calls reuse the
same execution and return its exact cwd and argv. All subsequent commands must
use both. `hold` and `release` also accept its browser ID. Stop compares the
daemon PID/start identity and session-file fingerprint, requests CLI `close`,
then checks process exit and writes a receipt. It never uses `kill-all`, deletes
project/session folders, or adopts previously running browsers. Browser test
cookies and transient page state are lost on normal close. The CLI status
includes registered browser runs under `browsers`; the existing native resource
cards still show simulators and volumes. Unregistered browser discovery and
cleanup require a separate explicit diagnosis.

References: [Codex hooks](https://learn.chatgpt.com/docs/hooks),
[Claude Code hooks](https://code.claude.com/docs/en/hooks).

## Installed CLI reuse

```bash
modore tools status vercel
modore tools resolve vercel@1.2.3
modore tools run vercel@1.2.3 -- --version
```

The version above is illustrative; use an exact version returned by status.
Only bounded package manifests and entrypoints are inspected, without walking
node_modules or querying a registry. Identical installed versions resolve to
one deterministic existing path across callers. No package is downloaded or
copied. Missing, ambiguous, or non-exact versions fail instead of silently
installing or substituting a different version. The child CLI retains its usual
behavior, including any network/build operations explicitly requested in its
arguments. This is a source-checkout CLI, not a new native app screen.

The synchronous guard catches common direct `npx vercel` and `npm exec` forms
when an installed version is available. It returns a deny decision with a
reuse command, not an allow decision or a rewritten deployment. It does not
intercept arbitrary scripts, enforce an OS-wide package policy, or serialize
first installations outside Modore. A `latest` tag requires checking whether
an upgrade is needed; an existing package is not proof of the registry latest.
Configuration and direct adapter tests do not prove host-side hook execution.
See [Codex hook trust and tool coverage](https://learn.chatgpt.com/docs/hooks).

## Agent access

```bash
modore mcp tools
```

This prints the read-only MCP surface. Do not register it globally without the
user choosing that boundary: results may contain local paths, process names, and
masked excerpts that the invoking client can send to its model provider.
