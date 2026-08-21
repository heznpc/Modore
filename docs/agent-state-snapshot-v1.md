# modore.agent-state-snapshot — v1

The wire contract for one workspace's session-binding snapshot, as
emitted by `scree.py bind <workspace>` and, per workspace, by
`scree.py bind-all`. This is the surface an external consumer (Zoint
first) may rely on. Everything not listed here is internal and may
change without notice.

## Shape

```json
{
  "schema": "modore.agent-state-snapshot",
  "schemaVersion": 1,
  "generatedAt": "2026-08-21T17:22:26+0900",
  "workspace": "/absolute/path",
  "repoUrl": "github.com/owner/name",
  "deep": true,
  "coverage": "complete",
  "coverageDetail": {
    "claude": "complete",
    "codex": "complete",
    "gemini": "complete",
    "editors": "complete",
    "unboundStores": []
  },
  "assessed": true,
  "storeFingerprint": { "digest": "…64 hex…", "fileCount": 7171 },
  "bindings": [
    {
      "provider": "claude",
      "sessionId": "…",
      "source": "/absolute/path/to/transcript",
      "subtranscripts": ["…"],
      "evidence": ["working-directory"],
      "confidence": "medium",
      "sizeBytes": 123456
    }
  ],
  "summary": { "total": 1, "byProvider": {}, "byConfidence": {}, "sizeBytes": 123456 }
}
```

`artifactRoot` (optional, editor entries only): the directory
`subtranscripts` are relative to, when the binder states it.

`coverage` ∈ `shallow | truncated | complete` · `confidence` ∈ `high |
medium | low` · `evidence[]` ⊆ `remote-url | working-directory |
file-access` · `provider` ∈ `claude | codex | gemini | vscode | kiro |
cursor | windsurf | antigravity`.

## Semantic limits — part of the contract

1. **`coverage: "complete"` means every candidate binding was
   conclusively classified** — decided by metadata authoritative enough
   on its own (a recorded remote, a matching cwd, a workspace hash), or
   read to EOF and found not to mention the workspace. It does **not**
   mean the machine was completely observed, and a consumer that reads
   it as total observation will over-trust an empty result.

2. **`storeFingerprint` identifies the session-store state observed at
   snapshot time**, for same-or-changed comparison before acting later.
   It is a metadata digest (paths, sizes, mtimes — nothing opened), not
   a provenance proof of anything inside the stores.

3. **A snapshot is historical evidence, never destructive
   authorization.** It records what was true when it was taken; sealing
   or deleting anything on its strength requires Modore to revalidate at
   the moment of action. The archive path's `revalidate` hook exists for
   exactly this, and a consumer holding a snapshot inherits the same
   duty.

## Versioning

Additive optional keys do not bump the version. Renaming, removing, or
changing the meaning of any key above does. A consumer receiving a
`schemaVersion` greater than it knows must treat the snapshot as
unreadable rather than best-effort parsing it — the fields it recognises
may no longer mean what they meant.

## Reference fixture

`tests/fixtures/agent-state-snapshot-v1.json` is generated from a real
run and pinned by `tests/test_scree.py`; consumer repositories copy that
file, never hand-write their own.
