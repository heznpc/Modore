import Foundation

public enum CollectionOutcome: String, Codable, Sendable {
    case complete, partial, failed, notCollected, unknown
}

public enum CollectionFailureCode: String, Codable, Sendable {
    case unavailable, unreadable, malformed, timedOut, cancelled, unsupported
}

public struct ProducerFailure: Equatable, Codable, Sendable {
    public let code: CollectionFailureCode
    public let recordID: String?
    /// Display only; never interpreted by assessment logic.
    public let detail: String

    public init(code: CollectionFailureCode, recordID: String? = nil, detail: String) {
        self.code = code
        self.recordID = recordID
        self.detail = detail
    }
}

public protocol EvidenceBackedRecord: Codable, Sendable {
    var evidence: EvidenceRecord { get }
}

/// Immutable facts from one run. Failures cannot masquerade as positive records.
public struct ProducerSnapshot<Record: EvidenceBackedRecord>: Codable, Sendable {
    public let producer: EvidenceSource
    public let runID: String
    public let schemaVersion: Int
    public let observedAt: Date?
    public let outcome: CollectionOutcome
    public let coverage: Coverage
    public let records: [Record]
    public let failures: [ProducerFailure]

    public init(producer: EvidenceSource, runID: String, schemaVersion: Int = 1,
                observedAt: Date?, outcome: CollectionOutcome, coverage: Coverage,
                records: [Record], failures: [ProducerFailure] = []) throws {
        guard !runID.isEmpty else { throw EvidenceContractError.emptyIdentity }
        guard schemaVersion == 1,
              (outcome == .complete || outcome == .partial || records.isEmpty),
              (outcome != .complete || failures.isEmpty),
              records.allSatisfy({ $0.evidence.reference.source == producer
                  && $0.evidence.reference.runID == runID }),
              Set(records.map { $0.evidence.reference.recordID }).count == records.count
        else { throw EvidenceContractError.invalidSnapshot }
        self.producer = producer
        self.runID = runID
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.outcome = outcome
        self.coverage = coverage
        self.records = records
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case producer, runID, schemaVersion, observedAt, outcome, coverage, records, failures
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(producer: values.decode(EvidenceSource.self, forKey: .producer),
                      runID: values.decode(String.self, forKey: .runID),
                      schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
                      observedAt: values.decodeIfPresent(Date.self, forKey: .observedAt),
                      outcome: values.decode(CollectionOutcome.self, forKey: .outcome),
                      coverage: values.decode(Coverage.self, forKey: .coverage),
                      records: values.decode([Record].self, forKey: .records),
                      failures: values.decode([ProducerFailure].self, forKey: .failures))
    }
}

extension ProducerSnapshot: Equatable where Record: Equatable {}
