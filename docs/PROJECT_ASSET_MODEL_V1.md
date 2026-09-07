# Project / Asset Model v1

Status: **Design intent — review before implementation.** The Swift declarations below
describe the first migration contract; they are not currently shipped APIs.

Modore explains the structure and provenance of durable local state, supplies evidence
for protection and recovery decisions, and revalidates every action at a separate
execution boundary. The project/asset model describes state and grants no authority.

## Baseline and scope

The baseline is [PR #109](https://github.com/heznpc/Modore/pull/109), merged into main
at `8e2f412` after full CI passed. Its five commits end at `1ac962f`: logical Codex session grouping,
multi-fragment inspection, checked recovery accounting, bounded previews, and a durable
display-only recovery journal. The native app was built and its Work and recovery-history
screens inspected; all 513 Mac tests passed locally, including the isolated live recovery harness.

Currently implemented:

- `WorkModels.swift` composes sessions, worktrees, repository assessments, scan failures,
  and unscanned roots into `WorkProject`.
- `StorageItem` has a transient UUID and path/kind/recipe fields; it has no project link.
  `StorageHistoryItem` persists a separate key and floating-point GiB estimates.
- `ObservedProcessRow` records PID, ownership and CPU, without a project path observation.
- `fileaccess.py` emits path/session associations and explicit content-scan omissions;
  it is not bundled and has no Swift caller.
- `RecoveryHistory` is display-only and contains no approval token.

The first implementation adds identity/evidence value types and adapts Work without
changing its rows, ordering, selection, counts, Git labels or action behavior. Storage
attribution is a subsequent change. No graph database, collector rewrite, parser split,
executor change or persistent content index belongs in that first implementation.

## Identity: preserve the current key without overstating it

`WorkProjectBuilder.canonical` currently removes one trailing slash and lowercases the
path. It does not call realpath, inspect case sensitivity, prove existence or verify a
repository. Root selection uses the longest known ancestor, then the conventional
`/.claude/worktrees/` or `/.git/worktrees/` shape. A conventional shape is inferred
membership, not confirmed Git registry membership.

The v1 project ID wraps this existing comparison key. Keep the original spelling for
display. Unknown workspace sessions retain the current unassigned bucket in the app;
that bucket is not a filesystem project and has no `ProjectIdentity`.

```swift
public struct ProjectIdentity: Hashable, Codable, Sendable {
    public let comparisonKey: String
}

public struct AssetIdentity: Hashable, Codable, Sendable {
    public let namespace: String
    public let key: String
}

public enum EvidenceSource: String, Codable, Sendable {
    case scree, repositoryAssessment, storageScan, processObservation
    case fileAccess, sessionBackup, cleanupReceipt, recoveryHistory
}

public enum ObservationState: String, Codable, Sendable {
    case observed, inferred, unknown, failed, notCollected
}

public enum CoverageState: String, Codable, Sendable {
    case complete, partial, unknown
}

public struct Coverage: Equatable, Codable, Sendable {
    public let state: CoverageState
    public let scope: String
    public let limitations: [String]
}

public enum EvidenceMethod: String, Codable, Sendable {
    case recordedWorkspace, knownRootAncestry, conventionalWorktreePath
    case gitRegistry, pathAncestry, projectManifest
    case processWorkingDirectory, processOpenFile
    case transcriptRead, transcriptWrite, transcriptShellReference
    case archiveHashVerification, cleanupReceipt, recoveryCheckpoint
}

public struct AssetEvidence: Equatable, Codable, Sendable {
    public let source: EvidenceSource
    public let observationID: String
    public let method: EvidenceMethod
    public let observedAt: Date?
    public let state: ObservationState
    public let coverage: Coverage
}
```

Implementation supplies explicit public initializers and validation at decoding/adaptation
boundaries. Identity fields must be nonempty; unknown identity stays outside these types.
Namespace values are adapter-owned constants, not arbitrary producer-controlled routes.
Initial namespaces distinguish filesystem paths, logical provider sessions and physical
transcript artifacts. A logical session key includes its provider; artifact keys cannot
reuse that session key. File replacement at the same path is a new observation, even
when its display identity remains the same. Observation IDs identify a producer run and
record, never a fresh UUID generated every time the same snapshot is rendered.

Pure domain types accept already interpreted values. Filesystem resolution, Git commands,
remote parsing and case-sensitivity probes stay in OS adapters. Repository remotes are
optional observed metadata, not identity: two clones of one remote remain two local
projects. Credential-bearing remote URLs must never enter display or evidence payloads.

Phase 1 retains today's case-folding behavior, including its limitation on case-sensitive
volumes. Correcting that behavior needs a separately reviewed identity migration and
selection/history compatibility tests. Never describe the legacy key as a verified
canonical root or use it as an executor target.

## Evidence and relation semantics

`observedAt` is the producer's observation time. Missing or ambiguous legacy timestamps
remain nil; adapter load time must not impersonate observation time. Collection time,
provider event time and source-file modification time are distinct. Freshness is assessed
by a consumer using a supplied clock and policy; it is not a durable `isFresh` Boolean.

Coverage is always relative to the declared scope. Complete enumeration of discovered
sessions says nothing about undiscovered stores or files beyond a content-read cap.
Partial scans may support positive observations but cannot prove absence. Do not turn
timeouts, omitted rows, unknown roots or empty failed results into “unused” or “safe”.
Conflicting evidence is retained for assessment rather than overwritten by latest arrival.

Phase 2 introduces a typed `ProjectAssetMembership` containing one asset, one project
and a nonempty evidence collection. This is the first `belongsTo` relation. Do not add
other relation cases until a producer and a consumer exist. The reserved vocabulary is:

| Relation | Direction and claim |
| --- | --- |
| belongsTo | asset → local project; attribution within a declared scope |
| producedBy | asset → observed producing task/tool; requires production evidence |
| usedBy | asset → process instance; requires observed cwd/open-file evidence |
| touchedBy | asset → logical session; retains read/write/shell-reference method |
| derivedFrom | asset → source artifact; lineage evidence, not rebuildability |
| backedUpBy | artifact → backup artifact; verification coverage remains explicit |
| protects | backup/retained artifact → protected subject; explicit protection evidence |
| observedWith | subject → another subject in one observation; no causal assertion |

Use dedicated endpoint types as each relation arrives, not a bag of arbitrary strings.
Process identity must include a start identity/time and observation context, since PIDs
are reused. A transcript tool invocation is a recorded claim about access; it does not
prove successful OS access. Shell references are weaker still. Keep these distinctions
in the method and assessment presented to the user.

Path ancestry, a project manifest, and a verified repository root are separate evidence
records. `node_modules` can be classified as a dependency candidate by its name, but that
does not establish that it can be rebuilt. Shared caches may have several consumers and
must not be forced into one owning project. Nested repositories use the most specific
established root; ambiguous, missing or symlink-dependent matches remain unresolved.

`ProtectionAssessment`, `RebuildAssessment`, `CleanupAssessment` and
`ContinuityAssessment` belong above these facts. Each assessment names its policy/version,
input observations, evaluation time, and reasons, with unknown/incomplete/conflicting
outcomes. None can construct an approval token, executable plan or validated target.

## Producer contract

Keep producer implementations and composition in app `Services/`; put only pure schema
and semantics in `shared/ModoreDomain`. The first Work adapter takes the existing inputs
to `WorkProjectBuilder` and associates their identity with the evidence actually supplied.
It does not request another scan or invent missing timestamps.

Subsequent adapters return immutable snapshots with a producer/run identifier, schema
version, observation time (when known), coverage, records and path-specific failures.
The application owns cancellation, time/output limits and publication of a consistent
snapshot. Late output from an earlier run cannot overwrite a newer observation. Existing
facts kept after a failed refresh retain their original time and show the refresh failure.

| Producer | Adaptation | Required limits/unknowns |
| --- | --- | --- |
| scree + Mothball | Work identities and membership evidence | root caps, scan failures, conventional worktree inference |
| storage scan | path asset, measured occupancy, project membership | invalid size/status, unknown ownership, overlapping paths |
| process observation | runtime usage evidence | current CPU row alone cannot identify a project; bounded path probes required |
| fileaccess | session/path touch evidence | propagate store failures, truncation, omitted IDs/rows, budget and timestamp limits |
| backup verification | backed-up artifact coverage | selected transcript never means all logical-session fragments |
| receipts + recovery history | historical outcomes | no retrospective token/plan reconstruction; unknown volume delta stays unknown |

Storage adapters convert legacy GiB only at the boundary using checked byte conversion;
they must inspect original measurement validity, since the current DTO can coerce malformed
input to zero. Occupancy uses nonnegative optional Int64 bytes, while volume change uses
signed optional Int64 bytes. Estimated/measured and partial/complete remain distinct.
Do not sum parent and child assets twice or infer a project's reclaimable total from sizes
alone. Keep old storage-history serialization until an explicit versioned migration exists.

Before fileaccess ships in the app, add its bounded Swift caller, bundled runtime allowlist
entry, transitive dependency/payload audit, decoder and failure-path tests together. Read
it through the existing pinned runtime/process transport. Metadata-only output is still
private owner data; use synthetic paths and transcripts in committed fixtures.

## Migration and acceptance gates

1. **Identity/evidence contract.** Add pure types and unit tests for invalid identity,
   serialization and unknown/partial observations. Adapt `WorkProject` with an optional
   identity for the unassigned case, preserving its existing String UI ID and initializer
   compatibility. Keep the builder algorithm and all action inputs unchanged. Run existing
   WorkProject/GitAssessmentState/selection tests and inspect the Work UI with the built app.
2. **Storage membership.** Introduce typed membership and a read-only composer. Verify
   nested roots, same-prefix sibling paths, unassigned assets, ambiguous ownership,
   symlinks, partial scans and overlap accounting. Work and Storage reference the same
   project key. UI explains attribution; cleanup still goes through its current preview.
3. **Runtime and touches.** Reuse fileaccess and add bounded runtime path evidence. Verify
   PID reuse, stale observations, denied probes and partial transcript coverage. Demonstrate
   a synthetic project's observed session/path relationship in the native app.
4. **Continuity.** Attach verified backup coverage and display-only recovery outcomes.
   Demonstrate restart rendering without approval resurrection; distinguish one fragment
   backed up from the entire logical session protected.
5. **Retrieval.** Separately design resumable large-file reads, an incremental SQLite
   content index, exact event locators, logical-session manifest backup and durable evidence
   packs. Logical grouping alone does not close large-artifact search coverage.

Each stage starts from integrated main, has its own PR and CI, and demonstrates the changed
behavior through the actual runtime. A test pass alone is not evidence of a working UI.
All stages preserve preview → fresh measurement → exact target → explicit approval →
process/filesystem revalidation → execution → receipt → volume measurement/history.
