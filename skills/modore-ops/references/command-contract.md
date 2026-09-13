# Modore command contract

## Session continuity

```bash
modore sessions current
modore sessions --limit 50
modore search --first                         # query bytes arrive on stdin
modore search --limit 20 --budget-seconds 30  # query bytes arrive on stdin
```

`sessions current` is the narrow first choice for the calling Codex task. It
uses `CODEX_THREAD_ID`/`CODEX_SESSION_ID` only as lookup hints, validates the
matching JSONL header, and reads no conversation body. `sessions` reads
metadata only and groups Codex rollout fragments by provider session ID while
retaining their physical sources. `search --first` returns the newest hit and
explicitly reports incomplete coverage. Ordinary `search` is the exhaustive
content-reading path;
snippets remain masked unless a user separately invokes lower-level raw mode.
The agent surface defaults session listing to 50 and caps it at 500; search is
capped at 200 matches, a 55-second internal budget, a 60-second outer wall
clock, and a 4096-byte UTF-8 query. Session listing has a 30-second outer wall
clock. Do not put the search phrase in shell history, process arguments, or a
temporary file.

Backup, verification, restore, and detailed inspection remain available through
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
modore resources begin-test --runtime <runtime> --provider <provider> --session <ID> --project <path> --turn <token>
modore resources hold --id <UDID> --provider <provider> --session <ID> --turn <token>
modore resources release --id <UDID> --provider <provider> --session <ID>
```

The installer merges two synchronous lifecycle hooks into the selected user's
configuration and backs up existing JSON under Modore's work-resource directory.
It preserves other hooks and does not grant trust. Codex requires review of both
definitions in `/hooks`; existing sessions may need a configuration refresh.

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
it is not proof of successful cleanup. This feature currently covers managed
simulator runs, not arbitrary browsers, processes, or sessions. Hook `Stop` can
also be an attempted turn finish followed by another hook's continuation; the
next simulator use must call `begin-test` again.

References: [Codex hooks](https://learn.chatgpt.com/docs/hooks),
[Claude Code hooks](https://code.claude.com/docs/en/hooks).

## Agent access

```bash
modore mcp tools
```

This prints the read-only MCP surface. Do not register it globally without the
user choosing that boundary: results may contain local paths, process names, and
masked excerpts that the invoking client can send to its model provider.
