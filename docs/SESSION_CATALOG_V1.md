# Session catalog v1

`python3 -I -B scripts/session_catalog.py --out /private/tmp/modore-catalog.json`
exports a local, versioned metadata snapshot for Taxi or another explicit file
consumer. It requires only Python's standard library and a Modore source
checkout. It is not an MCP registration, provider connection, or execution API.
The Modore app need not be installed or running.

## Wire contract

The JSON object has these required fields; consumers must reject unsupported
`schemaVersion` values and validate field types before storing the snapshot.

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer, exactly `1` | Contract version |
| `generatedAt` | string | Snapshot creation time, ISO-8601 UTC ending in `Z` |
| `source` | string, exactly `modore` | Producer |
| `scan.complete` | boolean | All configured discovery scopes and identity projection completed without reported gaps/conflicts |
| `scan.truncated` | boolean | A collector bound, aborted worker, or output limit prevented a complete snapshot |
| `scan.errors` | string array | Sorted, unique diagnostic codes; never exception messages, transcript snippets, commands, or credentials |
| `sessions` | object array | Logical provider sessions, newest observed activity first; stable key breaks ties |

Each session has exactly these required fields and may also have `title`:

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | string | Opaque, versioned, local storage-scoped identity, `modore:v1:` plus SHA-256 |
| `provider` | string | Currently `codex`, `claude`, `claude-desktop`, or `gemini` |
| `providerSessionId` | string or null | Existing provider metadata ID; Claude Code uses a UUID source filename. Gemini and unidentifiable records remain null |
| `profileKey` | string or null | Caller-supplied local Codex profile label, when unambiguous; unknown profiles remain null |
| `workspacePath` | string or null | Existing scree workspace metadata, null if absent, invalid, or conflicting across fragments |
| `lastActivityAt` | ISO-8601 UTC string or null | Latest valid observed metadata activity/file mtime, with microsecond precision; null when unavailable |
| `provenance` | string, exactly `local-metadata` | Local observation, not a provider API result |
| `title` | optional string | Only a bounded, already-masked title from Claude Desktop's dedicated metadata; omitted if absent or conflicting |

An empty complete catalog is valid. An incomplete catalog is also a valid
artifact, including when it contains no rows. `complete` is scoped to this
invocation's configured stores, not every profile or provider on the machine.
Consumers must preserve `generatedAt`, provenance and all scan fields. A prior
snapshot, partial scan, or missing row is not proof that a session was deleted.
No freshness TTL is imposed by v1; the consumer should display observation time.

## Identity, profiles, duplicates

The key hashes the JSON array `[provider, profileKey, storageNamespace,
identity]` using ASCII-escaped compact JSON and SHA-256. Identity is
`["session", providerSessionId]` when known, otherwise `["source", sourcePath]`.
Storage namespaces and transcript source paths are never separate output fields.
Paths are lexical absolute paths with standard macOS root aliases normalized;
they are not resolved through arbitrary provider-controlled symlinks.

- Default Codex, Claude Code and Gemini namespaces are their respective local
  store roots below the supplied home. Claude Desktop uses each dedicated
  metadata file's parent namespace, preserving separate account/organization
  directories even when their session IDs match.
- Codex rollout fragments and archive copies with the same ID in the same
  namespace/profile become one row. `lastActivityAt` is the maximum observation.
  Multiple nonempty workspace claims yield null and an explicit conflict.
  Unknown IDs stay separate by source path; there is no body/hash similarity
  merge. Cross-profile copies also stay separate.
- Profiles are never inferred from credentials, account names, nearby files,
  workspace equality, or timestamps. `profileKey: null` does not authorize a
  consumer to join two rows by `(provider, providerSessionId)` alone.
- A key remains stable as fragments are added inside one scope. Moving the
  store, changing an explicit label, or moving an unknown-ID source changes
  its key. Keys are local identities, not cross-machine/global identities.
- An explicit label is a caller assertion about a local root, not proof of an
  authenticated provider account. Same label on two roots preserves both
  identities and reports `codex:profile-key-conflict`. Different labels on one
  root scan that root once, keep its profile null and report
  `codex:profile-root-conflict`.
- Same provider session ID in multiple scopes stays separate and reports
  `<provider>:session-id-in-multiple-scopes`; this is ambiguity, not a claim
  that either record is corrupt. These conflicts make `complete` false while
  `truncated` remains false unless a separate bound was reached.

## Discovery and privacy

The exporter reuses `scree.collect_session_metadata` (the same physical
inventory as `build_sessions`) and `scree.collect_codex(store_root=...)` for
explicit additional Codex roots. It does not implement another disk parser.
The existing no-follow traversal, metadata byte/file/depth bounds, and coverage
statuses remain authoritative. Editor workspace-state rows are excluded because
they are not conversations; inventory errors from those collectors are retained
conservatively. Nested Claude subagent transcripts are not catalog sessions.

Metadata-only has the same precise boundary as scree: a bounded leading JSONL
record/prefix can contain message fields which the existing collector decodes
in memory and discards. No transcript body is searched for titles, identities,
relationships or status. No `title`, `inspect`, `search`, deep binding, backup,
restore, auth/config reader, or provider invocation is called by the exporter.
Only the output allowlist above survives projection. Title support does not add
reads beyond existing dedicated Desktop metadata. Local workspace paths and
session IDs are private owner data; real catalogs must not become public fixtures.

`lastActivityAt` is an observation, never evidence of running, idle, completed,
stopped, resumable, goal achieved, or ownership. There are no lifecycle, model,
parent/child, executable plan, transcript, credential or command fields.
Importing a catalog grants no execution/resume/cleanup authority. Consumers must
not execute strings from paths or titles. Parent/child relationships require
separate explicit creation or user records.

## Invocation and bounded failure

```bash
# Standard stores under the current home; create a private file.
python3 -I -B scripts/session_catalog.py --out /private/tmp/modore-catalog.json

# Explicit Codex roots; repeat the argument for additional local profiles.
python3 -I -B scripts/session_catalog.py \
  --codex-profile work /absolute/private/codex-home \
  --out /private/tmp/modore-work-catalog.json

# A synthetic home or a deliberate output cap.
python3 -I -B scripts/session_catalog.py --home /absolute/synthetic-home --limit 100
```

`--home` defaults to the current user's home. Environment variables such as
`CODEX_HOME` are not implicitly adopted; pass custom roots explicitly.
Additional profiles are not automatically enumerated. Naming the default
`.codex` root labels its existing scan without duplicating it. A missing default
provider store is normal; an explicitly named missing profile is an error.
Profile labels must be 1–256 characters with no control characters. A blank-only
label is invalid. `--limit 0` (default) returns all logical rows within the bounds;
a positive limit caps rows after discovery and grouping, not the discovery work.

`--budget-seconds` defaults to 30, accepts finite values greater than zero and
at most 60, and bounds discovery/projection through scree's existing isolated
JSON worker. The worker's result has a 64 MiB bound. A failed, oversized or
aborted worker returns a valid incomplete empty catalog; it never claims zero
sessions were conclusively found. The deadline does not cover final output file
I/O. Existing collector limits are not relaxed.

Diagnostics use these forms:

- `<store>:scan-unreadable`, `:scan-truncated`, `:scan-unrecognized`, or
  `:scan-unknown`; `<store>:unrecognized-metadata` also covers scree's unresolved
  metadata attribution. Store names are fixed lowercase provider/editor codes,
  or `discovery` for an unknown collector.
- `discovery:invalid-session-metadata` for an unprojectable session row.
- Profile/scope conflicts described above, and `codex:explicit-profile-missing`.
- `session:<key>:workspace-conflict` or `session:<key>:invalid-timestamp`.
- `catalog:limit` for a deliberately shortened output.
- `discovery:worker-time`, `:worker-unreadable`, or `:worker-worker-leaked` when
  the existing isolated transport cannot return its full result. `unreadable`
  includes worker exceptions/oversize; it does not identify the private cause.

Any diagnostic makes `complete` false. Null unknown IDs/profiles/workspaces alone
are allowed and do not imply scan failure. Invalid timestamps are null (or the
latest valid fragment value) and do add a diagnostic. A snapshot is not atomic
across stores; concurrently changed metadata may be reported as unrecognized.

Without `--out`, stdout contains the full catalog. With `--out`, the standard
scree private export writer creates a mode-0600 file with no-follow parent
traversal and verifies the bytes. It never overwrites a destination. An existing
name produces a fresh random sibling, and stdout is a receipt containing the
actual `outputPath` and `scan`. Consumers must use that path; do not assume an
old file was replaced. Newly created parent directories use mode 0700.

Exit codes: **0** complete catalog written; **1** incomplete catalog written
and usable with limitations; **2** invalid arguments or output failure.
No existing CLI/MCP schema, hook, registry, backup/restore or cleanup route is
replaced. See [product boundaries](PRODUCT_BOUNDARIES.md) for the Taxi transition.
