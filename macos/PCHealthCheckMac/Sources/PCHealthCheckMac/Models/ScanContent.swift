import Foundation

struct ScanContent {
    static let maximumRowsPerSection = 5_000
    static let empty = ScanContent(
        summary: nil,
        collectionCoverage: nil,
        macOSSecurity: nil,
        storage: nil,
        virusTotalEnabled: nil,
        findings: [],
        securityAttentionCount: 0,
        securityHasDanger: false,
        cpuRows: [],
        networkRows: [],
        listeningPortRows: [],
        autorunRows: [],
        recentInstalls: [],
        truncatedSections: []
    )

    let summary: ScanSummary?
    let collectionCoverage: CollectionCoverage?
    let macOSSecurity: MacOSSecurityStatus?
    let storage: StorageSnapshot?
    let virusTotalEnabled: Bool?
    let findings: [ScanFinding]
    let securityAttentionCount: Int
    let securityHasDanger: Bool
    let cpuRows: [CpuRow]
    let networkRows: [NetworkRow]
    let listeningPortRows: [ListeningPortRow]
    let autorunRows: [AutorunRow]
    let recentInstalls: [RecentInstallRow]
    let truncatedSections: [String]

    var securityAttentionFindings: [ScanFinding] {
        findings.filter(\.isSecurityAttention)
    }

    var storageAttentionFindings: [ScanFinding] {
        findings.filter { $0.requiresAttention && $0.isStorageOperational }
    }

    init(root: [String: Any]) {
        let sections = root["sections"] as? [String: Any]
        let findingRows = Self.rows(root["findings"])
        let cpuRows = Self.rows(sections?["cpu"])
        let networkRows = Self.rows(sections?["network"])
        let listeningPortRows = Self.rows(sections?["listeningPorts"])
        let autorunRows = Self.rows(sections?["autoruns"])
        let installRows = Self.rows(sections?["recentInstalls"])
        let findingClassification = Self.classifyFindings(findingRows)
        let virusTotal = sections?["virustotal"] as? [String: Any]
        let sectionRows = [
            "진단 결과": findingRows,
            "프로세스": cpuRows,
            "네트워크": networkRows,
            "수신 포트": listeningPortRows,
            "자동 실행": autorunRows,
            "최근 설치": installRows,
        ]
        self.init(
            summary: ScanSummary(json: root["summary"] as? [String: Any]),
            collectionCoverage: CollectionCoverage(json: root["collection"] as? [String: Any]),
            macOSSecurity: MacOSSecurityStatus(json: sections?["macosSecurity"] as? [String: Any]),
            storage: StorageSnapshot(json: sections?["storage"] as? [String: Any]),
            virusTotalEnabled: virusTotal.flatMap { JsonRead.bool($0, "enabled") },
            findings: findingRows.prefix(Self.maximumRowsPerSection).compactMap(ScanFinding.init(json:)),
            securityAttentionCount: findingClassification.count,
            securityHasDanger: findingClassification.hasDanger,
            cpuRows: cpuRows.prefix(Self.maximumRowsPerSection).compactMap(CpuRow.init(json:)),
            networkRows: networkRows.prefix(Self.maximumRowsPerSection).compactMap(NetworkRow.init(json:)),
            listeningPortRows: listeningPortRows.prefix(Self.maximumRowsPerSection)
                .compactMap(ListeningPortRow.init(json:)),
            autorunRows: autorunRows.prefix(Self.maximumRowsPerSection).compactMap(AutorunRow.init(json:)),
            recentInstalls: installRows.prefix(Self.maximumRowsPerSection).compactMap(RecentInstallRow.init(json:)),
            truncatedSections: sectionRows
                .filter { $0.value.count > Self.maximumRowsPerSection }
                .map(\.key)
                .sorted()
        )
    }

    private init(
        summary: ScanSummary?,
        collectionCoverage: CollectionCoverage?,
        macOSSecurity: MacOSSecurityStatus?,
        storage: StorageSnapshot?,
        virusTotalEnabled: Bool?,
        findings: [ScanFinding],
        securityAttentionCount: Int,
        securityHasDanger: Bool,
        cpuRows: [CpuRow],
        networkRows: [NetworkRow],
        listeningPortRows: [ListeningPortRow],
        autorunRows: [AutorunRow],
        recentInstalls: [RecentInstallRow],
        truncatedSections: [String]
    ) {
        self.summary = summary
        self.collectionCoverage = collectionCoverage
        self.macOSSecurity = macOSSecurity
        self.storage = storage
        self.virusTotalEnabled = virusTotalEnabled
        self.findings = findings
        self.securityAttentionCount = securityAttentionCount
        self.securityHasDanger = securityHasDanger
        self.cpuRows = cpuRows
        self.networkRows = networkRows
        self.listeningPortRows = listeningPortRows
        self.autorunRows = autorunRows
        self.recentInstalls = recentInstalls
        self.truncatedSections = truncatedSections
    }

    private static func rows(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func classifyFindings(_ rows: [[String: Any]]) -> (count: Int, hasDanger: Bool) {
        var count = 0
        var hasDanger = false
        for row in rows {
            let level = JsonRead.string(row, "level", "info")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard ScanFinding.isAttentionLevel(level),
                  !ScanFinding.isStorageCategory(JsonRead.string(row, "category")) else {
                continue
            }
            count += 1
            hasDanger = hasDanger || level == "danger"
        }
        return (count, hasDanger)
    }
}
