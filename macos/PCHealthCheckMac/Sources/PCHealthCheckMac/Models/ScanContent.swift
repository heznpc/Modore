import Foundation

struct ScanContent {
    static let maximumRowsPerSection = 5_000
    static let empty = ScanContent(
        summary: nil,
        macOSSecurity: nil,
        storage: nil,
        findings: [],
        cpuRows: [],
        networkRows: [],
        autorunRows: [],
        recentInstalls: [],
        truncatedSections: []
    )

    let summary: ScanSummary?
    let macOSSecurity: MacOSSecurityStatus?
    let storage: StorageSnapshot?
    let findings: [ScanFinding]
    let cpuRows: [CpuRow]
    let networkRows: [NetworkRow]
    let autorunRows: [AutorunRow]
    let recentInstalls: [RecentInstallRow]
    let truncatedSections: [String]

    init(root: [String: Any]) {
        let sections = root["sections"] as? [String: Any]
        let findingRows = Self.rows(root["findings"])
        let cpuRows = Self.rows(sections?["cpu"])
        let networkRows = Self.rows(sections?["network"])
        let autorunRows = Self.rows(sections?["autoruns"])
        let installRows = Self.rows(sections?["recentInstalls"])
        let sectionRows = [
            "진단 결과": findingRows,
            "프로세스": cpuRows,
            "네트워크": networkRows,
            "자동 실행": autorunRows,
            "최근 설치": installRows,
        ]
        self.init(
            summary: ScanSummary(json: root["summary"] as? [String: Any]),
            macOSSecurity: MacOSSecurityStatus(json: sections?["macosSecurity"] as? [String: Any]),
            storage: StorageSnapshot(json: sections?["storage"] as? [String: Any]),
            findings: findingRows.prefix(Self.maximumRowsPerSection).compactMap(ScanFinding.init(json:)),
            cpuRows: cpuRows.prefix(Self.maximumRowsPerSection).compactMap(CpuRow.init(json:)),
            networkRows: networkRows.prefix(Self.maximumRowsPerSection).compactMap(NetworkRow.init(json:)),
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
        macOSSecurity: MacOSSecurityStatus?,
        storage: StorageSnapshot?,
        findings: [ScanFinding],
        cpuRows: [CpuRow],
        networkRows: [NetworkRow],
        autorunRows: [AutorunRow],
        recentInstalls: [RecentInstallRow],
        truncatedSections: [String]
    ) {
        self.summary = summary
        self.macOSSecurity = macOSSecurity
        self.storage = storage
        self.findings = findings
        self.cpuRows = cpuRows
        self.networkRows = networkRows
        self.autorunRows = autorunRows
        self.recentInstalls = recentInstalls
        self.truncatedSections = truncatedSections
    }

    private static func rows(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }
}
