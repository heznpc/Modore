import Foundation

struct StorageHistoryItem: Codable, Identifiable, Equatable {
    let key: String
    let label: String
    let category: String
    let kind: String
    let sizeGB: Double
    let path: String
    let cleanupID: String
    let measureStatus: String?

    var id: String { key }
}

struct IncidentEvidenceSnapshot: Codable, Equatable {
    let processCount: Int
    let networkConnectionCount: Int
    let listeningPortCount: Int
    let attentionFindingCount: Int

    init(content: ScanContent) {
        processCount = content.cpuRows.count
        networkConnectionCount = content.networkRows.count
        listeningPortCount = content.listeningPortRows.count
        attentionFindingCount = content.findings.filter(\.requiresAttention).count
    }
}

struct StorageHistoryEntry: Codable, Identifiable, Equatable {
    let sourceID: String
    let capturedAt: Date
    let freeGB: Double
    let usedGB: Double
    let totalGB: Double
    /// Whether freeGB came from a real df measurement. Optional so results
    /// written before the flag decode as nil; treated as measured in that case.
    let freeSpaceMeasured: Bool?
    let items: [StorageHistoryItem]
    let incidentKind: String?
    let incidentTitle: String?
    let incidentValue: String?
    let collectionComplete: Bool?
    let browserVerdict: String?
    let evidence: IncidentEvidenceSnapshot?

    var id: String { sourceID }

    init(
        sourceID: String,
        capturedAt: Date,
        storage: StorageSnapshot,
        incident: IncidentAssessment? = nil,
        collectionComplete: Bool? = nil,
        evidence: IncidentEvidenceSnapshot? = nil
    ) {
        self.sourceID = sourceID
        self.capturedAt = capturedAt
        freeGB = storage.freeGB
        usedGB = storage.usedGB
        totalGB = storage.totalGB
        freeSpaceMeasured = storage.volumeMeasured
        incidentKind = incident?.kind.historyKey
        incidentTitle = incident?.title
        incidentValue = incident?.value
        self.collectionComplete = collectionComplete
        browserVerdict = storage.browserAutomation.verdict == "unknown"
            ? nil : storage.browserAutomation.verdict
        self.evidence = evidence

        var rows: [StorageHistoryItem] = []
        rows += Self.items(storage.cleanupCandidates, category: "cleanup")
        rows += Self.items(storage.reviewCandidates, category: "review")
        rows += Self.items(storage.developerToolchains, category: "developer")
        self.items = rows
    }

    init(
        sourceID: String,
        capturedAt: Date,
        freeGB: Double,
        usedGB: Double,
        totalGB: Double,
        items: [StorageHistoryItem],
        freeSpaceMeasured: Bool? = nil,
        incidentKind: String? = nil,
        incidentTitle: String? = nil,
        incidentValue: String? = nil,
        collectionComplete: Bool? = nil,
        browserVerdict: String? = nil,
        evidence: IncidentEvidenceSnapshot? = nil
    ) {
        self.sourceID = sourceID
        self.capturedAt = capturedAt
        self.freeGB = freeGB
        self.usedGB = usedGB
        self.totalGB = totalGB
        self.freeSpaceMeasured = freeSpaceMeasured
        self.items = items
        self.incidentKind = incidentKind
        self.incidentTitle = incidentTitle
        self.incidentValue = incidentValue
        self.collectionComplete = collectionComplete
        self.browserVerdict = browserVerdict
        self.evidence = evidence
    }

    private static func items(_ values: [StorageItem], category: String) -> [StorageHistoryItem] {
        var indexed: [String: StorageHistoryItem] = [:]
        for item in values {
            let identity = historyIdentity(
                category: category,
                kind: item.kind,
                cleanupID: item.cleanupID,
                path: item.path
            )
            indexed[identity] = StorageHistoryItem(
                key: identity,
                label: item.label,
                category: category,
                kind: item.kind,
                sizeGB: item.sizeGB,
                path: item.path,
                cleanupID: item.cleanupID,
                measureStatus: item.measureStatus
            )
        }
        return indexed.values.sorted { $0.key < $1.key }
    }

    static func historyIdentity(
        category: String,
        kind: String,
        cleanupID: String,
        path: String
    ) -> String {
        let recipe = cleanupID.isEmpty ? kind : cleanupID
        return "\(category)|\(recipe)|\(normalizedPath(path))"
    }

    static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "<unknown>" }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == "/" { return normalized }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }
}

struct StorageItemChange: Identifiable, Equatable {
    let key: String
    let label: String
    let category: String
    let path: String
    let beforeGB: Double
    let afterGB: Double
    let wasPresent: Bool
    let isPresent: Bool

    var id: String { key }
    var deltaGB: Double { afterGB - beforeGB }
    var appearedInTrackedList: Bool { !wasPresent && isPresent }
    var disappearedFromTrackedList: Bool { wasPresent && !isPresent }
    var hasMeasuredEndpoints: Bool { wasPresent && isPresent }
}

struct FreeSpaceSample: Identifiable, Equatable, Sendable {
    let checkedAt: Date
    let freeGB: Double
    let dropGB: Double
    let status: String

    var id: Date { checkedAt }
}
