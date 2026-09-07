import Foundation
import ModoreDomain

/// Revisions of the published inputs to WorkProjectBuilder, not task generations.
enum WorkInput: String, Codable, Sendable { case sessionIndex, screeReport, repoAssessments, repoScanFailures, reposNotScanned }

struct WorkProvenance {
    private(set) var inputRuns: [WorkInput: String] = [:]
    private(set) var compositionRunID = UUID().uuidString
    private(set) var composedAt = Date()

    /// Called only when an input is published, never by a getter or SwiftUI body.
    /// Even a same-valued newly published snapshot is a distinct observation run.
    mutating func didPublish(_ input: WorkInput) {
        inputRuns[input] = UUID().uuidString
        compositionRunID = UUID().uuidString
        composedAt = Date()
    }
}

/// What the provider recorded. Deliberately contains no inferred project identity.
struct WorkWorkspaceObservation: EvidenceBackedRecord, Equatable {
    let session: AssetIdentity
    let recordedWorkspace: String
    let evidence: EvidenceRecord
}

/// What Modore infers from the currently published combination of Work inputs.
/// The input claim keeps its original collection reference and timestamp.
struct WorkProjectAttribution: EvidenceBackedRecord, Equatable {
    let workspace: WorkWorkspaceObservation
    let project: ProjectIdentity
    let inputRuns: [WorkInput: String]
    let evidence: EvidenceRecord
}

struct WorkEvidence {
    let metadata: ProducerSnapshot<WorkWorkspaceObservation>?
    let attribution: ProducerSnapshot<WorkProjectAttribution>
}
