# Project / Asset Model v1

Status: **Phase 1 implemented; later migrations remain design intent.** The declarations
below summarize the contract. The validated public APIs live in `shared/ModoreDomain`;
the Work observations and adapter live in the Mac app. Storage/runtime integration remains planned.

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

The first implementation adds identity/provenance/coverage value types and one Work
producer adapter that emits actual evidence from session workspace inputs. It preserves
Work's rows, ordering, selection, counts, Git labels and action behavior. Storage
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
    case scree, projectAttribution, repositoryAssessment, storageScan, processObservation
    case fileAccess, sessionBackup, cleanupReceipt, recoveryHistory
}

public struct EvidenceReference: Hashable, Codable, Sendable {
    public let source: EvidenceSource
    public let runID: String
    public let recordID: String
}

// Positive support for a stated claim; never a collection result.
public enum EvidenceBasis: String, Codable, Sendable {
    case observed, inferred, recordedClaim, reference
}

public enum CollectionOutcome: String, Codable, Sendable {
    case complete, partial, failed, notCollected, unknown
}

public enum CoverageState: String, Codable, Sendable {
    case complete, partial, unknown
}

public struct Coverage: Equatable, Codable, Sendable {
    public let state: CoverageState
    // Opaque display descriptions. Consumers must not parse these strings.
    public let scope: String
    public let limitations: [String]
}

public enum EvidenceMethod: String, Codable, Sendable {
    case recordedWorkspace, knownRootAncestry, conventionalWorktreePath, workspaceFallback
    case gitRegistry, pathAncestry, projectManifest
    case processWorkingDirectory, processOpenFile
    case transcriptReadInvocation, transcriptWriteInvocation, transcriptShellReference
    case archiveHashVerification, cleanupReceipt, recoveryCheckpoint
}

public struct EvidenceRecord: Equatable, Codable, Sendable {
    public let reference: EvidenceReference
    public let method: EvidenceMethod
    public let basis: EvidenceBasis
    public let observedAt: Date?
    public let coverage: Coverage
}

public enum CollectionFailureCode: String, Codable, Sendable {
    case unavailable, unreadable, malformed, timedOut, cancelled, unsupported
}

public struct ProducerFailure: Equatable, Codable, Sendable {
    public let code: CollectionFailureCode
    public let recordID: String?
    public let detail: String // Display only; never an assessment input.
}

public protocol EvidenceBackedRecord: Codable, Sendable {
    var evidence: EvidenceRecord { get }
}

public struct ProducerSnapshot<Record: EvidenceBackedRecord>: Codable, Sendable {
    public let producer: EvidenceSource
    public let runID: String
    public let schemaVersion: Int
    public let observedAt: Date?
    public let outcome: CollectionOutcome
    public let coverage: Coverage
    public let records: [Record]
    public let failures: [ProducerFailure]
}
```

Implementation supplies explicit public initializers and validation at decoding/adaptation
boundaries. Identity fields must be nonempty; unknown identity stays outside these types.
Namespace values are adapter-owned constants, not arbitrary producer-controlled routes.
Initial namespaces distinguish filesystem paths, logical provider sessions and physical
transcript artifacts. A logical session key includes its provider; artifact keys cannot
reuse that session key. File replacement at the same path is a new observation, even
when its display identity remains the same. An `EvidenceReference` is the explicit tuple
`source + runID + recordID`: run IDs identify collection attempts; record IDs are unique
within that producer run. References remain stable when a snapshot is rendered again.
New collection attempts receive new run IDs even if their values happen to match. Validate
nonempty IDs and require every emitted evidence reference to match its enclosing snapshot's
producer/run. Assessment inputs retain these exact references, not display strings or
an ambiguous combined observation ID. A reference identifies evidence, not an executable target.

Pure domain types accept already interpreted values. Filesystem resolution, Git commands,
remote parsing and case-sensitivity probes stay in OS adapters. Repository remotes are
optional observed metadata, not identity: two clones of one remote remain two local
projects. Credential-bearing remote URLs must never enter display or evidence payloads.

Phase 1 retains today's case-folding behavior, including its limitation on case-sensitive
volumes. Correcting that behavior needs a separately reviewed identity migration and
selection/history compatibility tests. Never describe the legacy key as a verified
canonical root or use it as an executor target.

## Evidence and relation semantics

Keep three layers separate, followed by the existing action boundary:

```text
Collection outcome: complete / partial / failed / notCollected / unknown
    → Evidence: observed / inferred / recordedClaim / reference
    → Assessment: protection / rebuildability / cleanup / continuity
    → Action planning + independent revalidation
```

`EvidenceRecord` contains only positive factual support and its provenance. It has no
failed, unknown or not-collected case. `CollectionOutcome`, coverage and producer failures
describe collection, not relations. Unknown attribution is an unresolved attribution result
in app composition, never `belongsTo(unknown)` or a membership supported only by a failure.
The typed observation containing an evidence record must state its subject and claim;
provenance by itself is not a fact about arbitrary endpoints.

`EvidenceBasis` qualifies that claim, not the certainty of the collection machinery.
For example, a transcript Read invocation uses `transcriptReadInvocation + recordedClaim`:
the record supports “this session recorded a Read invocation for this path,” not “the OS
successfully read this file.” A shell path mention uses `transcriptShellReference + reference`.
Adapters must validate method/basis combinations; neither can be silently promoted to
direct OS access evidence. `recordedWorkspace` supports a provider-recorded workspace claim;
ancestry and conventional worktree mapping are separate inferred claims.

`observedAt` is the producer's observation time. Missing or ambiguous legacy timestamps
remain nil; adapter load time must not impersonate observation time. Collection time,
provider event time and source-file modification time are distinct. Freshness is assessed
by a consumer using a supplied clock and policy; it is not a durable `isFresh` Boolean.

Coverage is always relative to the declared scope. Complete enumeration of discovered
sessions says nothing about undiscovered stores or files beyond a content-read cap.
Partial scans may support positive observations but cannot prove absence. Do not turn
timeouts, omitted rows, unknown roots or empty failed results into “unused” or “safe”.
Conflicting evidence is retained for assessment rather than overwritten by latest arrival.

`Coverage.scope` is an opaque, display-only explanation, and `limitations` are display-only
diagnostics. Consumers must not parse, compare labels or search these strings to choose a
verdict. A producer that needs machine-readable scope adds its own typed endpoint/scope
contract alongside coverage. This is required before proving absence: `.complete` plus a
scope string alone cannot establish that the relevant stores, paths or time range were
exhaustively examined. Use typed outcome/failure codes for control flow; add typed limit
fields when a consumer needs them, rather than interpreting diagnostic text.

Phase 2 introduces a typed `ProjectAssetMembership` containing one asset, one project
and positive evidence specifically supporting those endpoints and that membership claim.
Its validated constructor requires nonempty relevant evidence, not just an arbitrary
nonempty array: unrelated observations or a shell reference alone cannot establish ownership.
Without that support, the composer retains unresolved attribution and creates no membership.
This is the first shared `belongsTo` relation; Phase 1 already emits a scoped Work observation
from the existing workspace input without introducing a general relationship model. Do not add
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
exact input `EvidenceReference` values, evaluation time, and typed outcome/reasons,
including unknown/incomplete/conflicting outcomes. None can construct an approval token,
executable plan or validated target.

## Producer contract

Keep producer implementations and composition in app `Services/`; put only pure schema
and semantics in `shared/ModoreDomain`. The Work adapter emits separate records:
`WorkWorkspaceObservation` carries the provider's recorded workspace with `.scree` provenance;
`WorkProjectAttribution` carries the builder's inferred project mapping with
`.projectAttribution` provenance and its input observation. An unknown workspace produces
neither and stays in the unassigned bucket. Physical artifact identity remains explicit
when no logical provider ID exists.

Each accepted session-index publication gets a collection run ID. Each publication of any
builder input (session index, scree report, repository assessments, failures or unscanned roots)
also gets a new composition run ID and retains the input revision tuple. Root-only changes
never relabel the session observation. `WorkProvenance` creates IDs at these publication
boundaries, not in `workProjects`, adapters or SwiftUI bodies. Task generations remain
separate stale-write controls. Failed/cancelled loads cannot re-stamp retained facts.

The adapter emits separate `ProducerSnapshot<WorkWorkspaceObservation>` and
`ProducerSnapshot<WorkProjectAttribution>` envelopes. Record IDs identify input positions
within immutable runs; repeated adaptation retains references. The collector timestamp is
unknown when absent from the DTO; composition time describes the actual inference. The
existing builder supplies both the root and the matching rule, including an explicitly
inferred workspace fallback. Work rows attach the result without changing their legacy
String IDs, equality, sorting, selection or action behavior.

Snapshots distinguish collection outcome from positive records. Failed/not-collected/unknown
attempts emit no current positive records; recovered valid records from a run interrupted by
failure require `.partial` and explicit coverage/failures. `.complete` means the producer
finished its declared collection, not that every possible product claim has complete coverage.
Record coverage may still be partial, for example when a metadata listing completes but
content was bounded. Failures refer to affected input record IDs when known and do not
become `EvidenceReference` values. Old successful records remain in their original snapshot.

Subsequent producers/adapters use the same immutable envelope, with their own typed payloads
and scope contracts where needed. Phase 2 and Phase 3 require producer/DTO contract changes,
not merely adapters over today's lossy or incomplete rows.
The application owns cancellation, time/output limits and publication of a consistent
snapshot. Late output from an earlier run cannot overwrite a newer observation. Existing
facts kept after a failed refresh retain their original time and show the refresh failure.

| Producer | Adaptation | Required limits/unknowns |
| --- | --- | --- |
| scree + Mothball | Work identities and membership evidence | root caps, scan failures, conventional worktree inference |
| storage scan | preserve raw measurement validity before DTO coercion, then compose assets/membership | invalid size/status, unknown ownership, overlapping paths |
| process observation | extend producer and DTO with process instance identity, then runtime evidence | PID alone is insufficient; bounded start-identity/path probes required |
| fileaccess | session/path touch evidence | propagate store failures, truncation, omitted IDs/rows, budget and timestamp limits |
| backup verification | backed-up artifact coverage | selected transcript never means all logical-session fragments |
| receipts + recovery history | historical outcomes | no retrospective token/plan reconstruction; unknown volume delta stays unknown |

Phase 2 must first extend the storage decoder/DTO to retain raw measurement validity before
coercion. The current `StorageItem` has already turned malformed/non-finite `sizeGB` into
zero; an adapter downstream cannot recover whether that zero was measured. Preserve a typed
measurement state and optional checked byte value while keeping legacy display fields
compatible. Perform conversion where raw values are still available, distinguishing missing,
malformed, non-finite, overflow and timed-out values from a valid measured zero. Do not
infer validity from the coerced DTO value or a default `measureStatus`.
Occupancy uses nonnegative optional Int64 bytes, while volume change uses
signed optional Int64 bytes. Estimated/measured and partial/complete remain distinct.
Do not sum parent and child assets twice or infer a project's reclaimable total from sizes
alone. Keep old storage-history serialization until an explicit versioned migration exists.

Phase 3 must extend the observation producer and `ObservedProcessRow` contract with a
process start identity/time and collection context before emitting `usedBy`. Today's PID
and transient row UUID cannot distinguish reused PIDs. Collect start identity and bounded
cwd/open-file evidence for the same process instance, rechecking instance identity around
the probes. Missing/denied start data or an instance change yields unresolved runtime
attribution; never synthesize a start time from collection time or treat a UUID as OS identity.

Before fileaccess ships in the app, add its bounded Swift caller, bundled runtime allowlist
entry, transitive dependency/payload audit, decoder and failure-path tests together. Read
it through the existing pinned runtime/process transport. Metadata-only output is still
private owner data; use synthetic paths and transcripts in committed fixtures.

## Migration and acceptance gates

1. **Identity/evidence contract.** Add pure identity/provenance/coverage types and the
   snapshot envelope, then one Work workspace producer adapter. Test real `SessionIndexEntry`
   fixtures through that adapter: a recorded workspace creates the expected positive
   evidence and exact source/run/record reference; inferred ancestor mapping remains
   distinct; an empty workspace creates none. Verify repeat adaptation preserves references,
   a new run changes provenance, and missing timestamps remain unknown. Test partial/failed/
   not-collected snapshots without manufacturing evidence from collection failures.
   Check invalid identity, serialization and snapshot/reference consistency. Adapt
   `WorkProject` with an optional identity for the unassigned case, preserving its String UI ID and initializer
   compatibility. Keep the builder algorithm and all action inputs unchanged. Assert
   identical IDs, row equality, ordering, selection and UI output for the same fixtures;
   run existing WorkProject/GitAssessmentState/selection tests and inspect the Work UI with
   the built app. Unused evidence scaffolding does not satisfy this gate. Storage is excluded.
2. **Storage membership.** First preserve validity in the raw decoder/DTO and test valid
   zero versus missing, malformed, non-finite, overflow and timed-out measurements. Then
   introduce validated typed membership and a read-only composer; no supporting evidence
   means unresolved attribution. Verify nested roots, same-prefix sibling paths,
   unassigned assets, ambiguous ownership,
   symlinks, partial scans and overlap accounting. Work and Storage reference the same
   project key. UI explains attribution; cleanup still goes through its current preview.
3. **Runtime and touches.** Extend the process producer/DTO with start identity and collection
   context, and verify that probes refer to that same instance. Reuse fileaccess and add
   bounded runtime path evidence. Test PID reuse during probing, missing start identity,
   stale observations, denied probes and partial transcript coverage. Verify transcript
   invocation/reference evidence never becomes successful OS access evidence. Demonstrate
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
