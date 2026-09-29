# Product boundaries and compatibility transition

Taxi is the integrated AI work environment: requests, planning, research,
implementation, verification, model selection, session branching/handoffs,
execution observation, stop/resume and result review belong in its work flow.
The manager may be the user or an explicitly authorized AI session; no resident
manager model is required.

Modore remains an independent local preservation, recovery and cleanup product.
Its reusable assets are session/file/workspace connections, loss-risk evidence,
verified backups, restore, residue analysis and deterministic local assessments.
Taxi may reuse these capabilities without requiring the Modore app to be
installed or running. A shared capability's maintenance owner is separate from
where its UI appears; reuse does not create a separate consumer product.

QuotaPie remains an independent quota/usage/model-operations product. Taxi may
embed its shared policy and normalization engine without requiring QuotaPie to
run. Existing optional QuotaPie observation in Modore remains compatible.

## Implemented boundary

[Session catalog v1](SESSION_CATALOG_V1.md) is an explicit metadata-only file
handoff from Modore to a consumer. It retains local provenance, observation time,
unknown profiles and incomplete coverage. It does not transfer execution
ownership. A consumer can observe/link an external session and route an explicit
open action through a supported provider surface; it must not treat a catalog
row as permission or capability to resume it.

The catalog does not inspect conversation bodies for titles or relationships,
infer lifecycle from mtime, create parent/child links from matching workspaces,
or expose command plans. Taxi-created relationships or explicit user records
are separate evidence. Unsupported provider control remains unverified.

Modore's existing CLI/MCP listing, explicit content-search boundary, backup
verification/restore and cleanup approval/receipt contracts remain in place.
Cleanup still requires a current, identified target and the established Modore
approval boundary. A catalog is neither a backup nor deletion authorization.

## Test resource execution: staged migration

Long term, test-resource execution belongs to Taxi's execution layer. Modore
observes resource/session connections and preserves evidence and recovery data.
This direction does not retroactively move active ownership.

1. Existing Modore `resources begin-test`, `begin-browser-test`, `hold`,
   `release`, registry files, lifecycle hooks and receipts remain compatible.
   Their currently registered runs are still controlled by their existing
   Modore owner and verified fingerprints.
2. A future Taxi executor must record an explicit execution owner, durable run
   identity, resource identity, and supported stop/resume semantics before it
   starts owning new runs. Modore can observe those published facts and retain
   preservation evidence. A copied catalog or registration is insufficient.
3. Existing runs finish through the owner that created them. A future handoff
   needs an explicit protocol and fresh identity/ownership checks, with one
   authority for each run. Until that exists, do not reassign or dual-control
   live resources, automatically trust hooks, or migrate user profiles.
4. Only after compatibility and real execution are verified can old launch
   routes be deprecated. This change removes no CLI, edits no installed hook
   configuration, and terminates or deletes no existing resource.

The registry and receipt paths documented in [work resource control](WORK_RESOURCE_CONTROL.md)
remain the current implementation contract. “All state belongs to Modore” is
not a cross-product rule: Taxi owns its future execution records; Modore owns
its preservation/cleanup records and still-existing compatibility runs.
A standalone Modore user does not gain a Taxi dependency through this transition.

## Verification limits

Synthetic contract tests prove projection, duplicate/profile isolation, error
reporting, privacy output boundaries and create-only private export behavior.
Running the exporter on local metadata separately verifies actual discovery.
Neither proves a Taxi UI import, provider resume, model observation, or a future
resource executor. Those require their consumer's own real execution evidence.
Real catalogs and integration handoffs stay in private local storage and are
never committed as tests or documentation examples.
