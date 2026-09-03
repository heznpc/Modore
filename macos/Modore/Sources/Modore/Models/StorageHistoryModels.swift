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
        // The aggregate Devices root is the counted source of truth because it
        // also includes orphaned/unavailable UUID directories that simctl cannot
        // enrich. Per-device rows remain as drill-down evidence in a non-counted
        // category so history can explain which known device changed without
        // adding those bytes a second time.
        rows += Self.items(
            storage.developerToolchains.filter { !$0.kind.hasPrefix("simulator_") },
            category: "developer"
        )
        rows += Self.items(
            storage.developerToolchains.filter { $0.kind.hasPrefix("simulator_") },
            category: "simulator"
        )
        rows += Self.simulatorItems(storage.simulatorDevices)
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

    private static func simulatorItems(_ values: [SimulatorDevice]) -> [StorageHistoryItem] {
        var indexed: [String: StorageHistoryItem] = [:]
        for device in values {
            // This is a history identity, not an executable cleanup recipe.
            // Bind it directly to the canonical UUID so a recipe-label change
            // or UUID casing difference cannot split one device across scans.
            let canonicalUUID = UUID(uuidString: device.uuid)?.uuidString
                ?? device.uuid.uppercased()
            let historyCleanupID = "simulator_device:\(canonicalUUID)"
            let identity = historyIdentity(
                category: "simulator_detail",
                kind: "simulator_device",
                cleanupID: historyCleanupID,
                path: device.path
            )
            indexed[identity] = StorageHistoryItem(
                key: identity,
                label: device.name,
                category: "simulator_detail",
                kind: "simulator_device",
                sizeGB: device.sizeGB,
                path: device.path,
                cleanupID: historyCleanupID,
                measureStatus: device.measureStatus
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
        // Simulator toolchains were persisted under `developer` before the
        // dedicated Simulator surface existed. Canonicalize both forms so an
        // upgrade cannot report the unchanged footprint as one disappearance
        // plus one new multi-gigabyte allocation.
        let simulatorHistoryCategories = ["developer", "simulator", "simulator_detail"]
        let identityCategory = kind.hasPrefix("simulator_")
            && simulatorHistoryCategories.contains(category)
            ? "simulator"
            : category
        let recipe = cleanupID.isEmpty ? kind : cleanupID
        return "\(identityCategory)|\(recipe)|\(normalizedPath(path))"
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
    let kind: String
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
    var isAttributionDetail: Bool {
        category == "simulator_detail" || kind == "simulator_device"
    }
}

struct FreeSpaceSample: Identifiable, Equatable, Sendable {
    let checkedAt: Date
    let freeGB: Double
    let dropGB: Double
    let status: String

    var id: Date { checkedAt }
}
