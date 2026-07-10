import Foundation

struct ScanContent {
    static let empty = ScanContent(
        summary: nil,
        macOSSecurity: nil,
        storage: nil,
        findings: [],
        cpuRows: [],
        networkRows: [],
        autorunRows: [],
        recentInstalls: []
    )

    let summary: ScanSummary?
    let macOSSecurity: MacOSSecurityStatus?
    let storage: StorageSnapshot?
    let findings: [ScanFinding]
    let cpuRows: [CpuRow]
    let networkRows: [NetworkRow]
    let autorunRows: [AutorunRow]
    let recentInstalls: [RecentInstallRow]

    init(root: [String: Any]) {
        let sections = root["sections"] as? [String: Any]
        self.init(
            summary: ScanSummary(json: root["summary"] as? [String: Any]),
            macOSSecurity: MacOSSecurityStatus(json: sections?["macosSecurity"] as? [String: Any]),
            storage: StorageSnapshot(json: sections?["storage"] as? [String: Any]),
            findings: Self.rows(root["findings"]).compactMap(ScanFinding.init(json:)),
            cpuRows: Self.rows(sections?["cpu"]).compactMap(CpuRow.init(json:)),
            networkRows: Self.rows(sections?["network"]).compactMap(NetworkRow.init(json:)),
            autorunRows: Self.rows(sections?["autoruns"]).compactMap(AutorunRow.init(json:)),
            recentInstalls: Self.rows(sections?["recentInstalls"]).compactMap(RecentInstallRow.init(json:))
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
        recentInstalls: [RecentInstallRow]
    ) {
        self.summary = summary
        self.macOSSecurity = macOSSecurity
        self.storage = storage
        self.findings = findings
        self.cpuRows = cpuRows
        self.networkRows = networkRows
        self.autorunRows = autorunRows
        self.recentInstalls = recentInstalls
    }

    private static func rows(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }
}
