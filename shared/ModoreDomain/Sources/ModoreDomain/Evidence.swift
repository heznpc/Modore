import Foundation

public enum EvidenceSource: String, Codable, Sendable {
    case scree, projectAttribution, repositoryAssessment, storageScan, processObservation
    case fileAccess, sessionBackup, cleanupReceipt, recoveryHistory
}

public struct EvidenceReference: Hashable, Codable, Sendable {
    public let source: EvidenceSource
    public let runID: String
    public let recordID: String

    public init(source: EvidenceSource, runID: String, recordID: String) throws {
        guard !runID.isEmpty, !recordID.isEmpty else { throw EvidenceContractError.emptyIdentity }
        self.source = source
        self.runID = runID
        self.recordID = recordID
    }

    private enum CodingKeys: String, CodingKey { case source, runID, recordID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: values.decode(EvidenceSource.self, forKey: .source),
                      runID: values.decode(String.self, forKey: .runID),
                      recordID: values.decode(String.self, forKey: .recordID))
    }
}

/// Positive support for the containing record's claim, never a collection result.
public enum EvidenceBasis: String, Codable, Sendable {
    case observed, inferred, recordedClaim, reference
}

public enum CoverageState: String, Codable, Sendable { case complete, partial, unknown }

public struct Coverage: Equatable, Codable, Sendable {
    public let state: CoverageState
    /// Opaque display descriptions. Never parse these strings to make a judgment.
    public let scope: String
    public let limitations: [String]

    public init(state: CoverageState, scope: String, limitations: [String] = []) {
        self.state = state
        self.scope = scope
        self.limitations = limitations
    }
}

public enum EvidenceMethod: String, Codable, Sendable {
    case recordedWorkspace, knownRootAncestry, conventionalWorktreePath, workspaceFallback
    case gitRegistry, pathAncestry, projectManifest
    case processWorkingDirectory, processOpenFile
    case transcriptReadInvocation, transcriptWriteInvocation, transcriptShellReference
    case archiveHashVerification, cleanupReceipt, recoveryCheckpoint

    public var basis: EvidenceBasis {
        switch self {
        case .recordedWorkspace, .transcriptReadInvocation, .transcriptWriteInvocation:
            return .recordedClaim
        case .knownRootAncestry, .conventionalWorktreePath, .workspaceFallback, .pathAncestry:
            return .inferred
        case .transcriptShellReference: return .reference
        default: return .observed
        }
    }
}

/// Provenance only. A typed containing record supplies the subject and factual claim.
/// There is deliberately no failed/unknown evidence or execution capability here.
public struct EvidenceRecord: Equatable, Codable, Sendable {
    public let reference: EvidenceReference
    public let method: EvidenceMethod
    public let basis: EvidenceBasis
    public let observedAt: Date?
    public let coverage: Coverage

    public init(reference: EvidenceReference, method: EvidenceMethod, basis: EvidenceBasis,
                observedAt: Date?, coverage: Coverage) throws {
        guard basis == method.basis else { throw EvidenceContractError.invalidMethodBasis }
        self.reference = reference
        self.method = method
        self.basis = basis
        self.observedAt = observedAt
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey { case reference, method, basis, observedAt, coverage }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: values.decode(EvidenceReference.self, forKey: .reference),
                      method: values.decode(EvidenceMethod.self, forKey: .method),
                      basis: values.decode(EvidenceBasis.self, forKey: .basis),
                      observedAt: values.decodeIfPresent(Date.self, forKey: .observedAt),
                      coverage: values.decode(Coverage.self, forKey: .coverage))
    }
}
