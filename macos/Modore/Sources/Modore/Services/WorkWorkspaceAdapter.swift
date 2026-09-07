import Foundation
import ModoreDomain

/// Pure adaptation of immutable published inputs. No filesystem reads, UUID creation,
/// action eligibility, or approval state. The existing builder owns the mapping rule.
enum WorkWorkspaceAdapter {
    static func adapt(index: SessionIndex?, roots: Set<String>, provenance: WorkProvenance) throws -> WorkEvidence {
        let attributionCoverage = Coverage(
            state: .unknown, scope: "Current Work workspace attribution",
            limitations: ["Legacy case-folded mapping; repository and filesystem coverage are not established."])
        guard let index, let sessionRun = provenance.inputRuns[.sessionIndex] else {
            return WorkEvidence(metadata: nil, attribution: try ProducerSnapshot(
                producer: .projectAttribution, runID: provenance.compositionRunID,
                observedAt: provenance.composedAt, outcome: .notCollected,
                coverage: attributionCoverage, records: []))
        }

        let complete = index.coverage.complete && index.total == index.sessions.count
        let coverageState: CoverageState = complete ? .complete
            : (index.total != index.sessions.count || !index.coverage.stores.isEmpty ? .partial : .unknown)
        let metadataCoverage = Coverage(
            state: coverageState, scope: "Returned session-index workspace metadata",
            limitations: complete ? [] : ["Session discovery or returned rows are incomplete; no absence claim."])
        var observations: [WorkWorkspaceObservation] = []
        var attributions: [WorkProjectAttribution] = []
        var failures: [ProducerFailure] = []
        for (offset, session) in index.sessions.enumerated() {
            // Unknown workspace is an unassigned UI bucket, never a factual membership.
            guard !session.workspace.isEmpty else { continue }
            let provider = session.tool.lowercased()
            let logicalID = session.providerSessionId.flatMap { $0.isEmpty ? nil : $0 }
            let identity = logicalID ?? session.source
            guard !provider.isEmpty, !identity.isEmpty else {
                failures.append(ProducerFailure(code: .malformed, recordID: "\(offset)",
                                                detail: "Session identity is missing."))
                continue
            }
            // Length framing keeps provider/key tuples unambiguous. Physical fallback
            // never pretends that a provider lacking a logical ID supplied one.
            let asset = try AssetIdentity(namespace: logicalID == nil ? "session-artifact" : "logical-session",
                                          key: "\(provider.utf8.count):\(provider)\(identity)")
            let observation = WorkWorkspaceObservation(
                session: asset, recordedWorkspace: session.workspace,
                evidence: try EvidenceRecord(
                    reference: EvidenceReference(source: .scree, runID: sessionRun, recordID: "workspace:\(offset)"),
                    method: .recordedWorkspace, basis: .recordedClaim,
                    // SessionIndex carries no collector timestamp. lastActive is an
                    // event timestamp and must not impersonate observation time.
                    observedAt: nil, coverage: metadataCoverage))
            observations.append(observation)
            let mapping = WorkProjectBuilder.projectMapping(for: session.workspace, roots: roots)
            attributions.append(WorkProjectAttribution(
                workspace: observation,
                project: try ProjectIdentity(comparisonKey: WorkProjectBuilder.canonical(mapping.path)),
                inputRuns: provenance.inputRuns,
                evidence: try EvidenceRecord(
                    reference: EvidenceReference(source: .projectAttribution,
                                                 runID: provenance.compositionRunID, recordID: "attribution:\(offset)"),
                    method: mapping.method, basis: .inferred,
                    observedAt: provenance.composedAt, coverage: attributionCoverage)))
        }
        let outcome: CollectionOutcome = complete && failures.isEmpty ? .complete : .partial
        let snapshotCoverage = failures.isEmpty ? metadataCoverage : Coverage(
            state: .partial, scope: metadataCoverage.scope,
            limitations: metadataCoverage.limitations + ["Invalid session identities could not be adapted."])
        return WorkEvidence(
            metadata: try ProducerSnapshot(producer: .scree, runID: sessionRun, observedAt: nil,
                                           outcome: outcome, coverage: snapshotCoverage,
                                           records: observations, failures: failures),
            attribution: try ProducerSnapshot(producer: .projectAttribution,
                                              runID: provenance.compositionRunID,
                                              observedAt: provenance.composedAt, outcome: outcome,
                                              coverage: attributionCoverage, records: attributions))
    }
}
