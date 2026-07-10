import Foundation
import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published var state: ScanState = .idle
    @Published private(set) var content = ScanContent.empty
    @Published var selectedReportURL: URL?
    @Published var selectedReportTitle = "리포트"
    @Published var errorMessage: String?
    @Published var reportRevision = 0
    @Published var virusTotalEnabled = false
    @Published var cleanupPreview: CleanupPreview?
    @Published var cleanupInFlight = false
    @Published private(set) var storageHistory: [StorageHistoryEntry] = []
    @Published private(set) var storageChange: StorageChangeSummary?
    @Published private(set) var freeSpaceSamples: [FreeSpaceSample] = []
    @Published private(set) var simulatorKeepNames: Set<String> = []
    @Published var storageWatchEnabled = false
    @Published var storageWatchDetail = "상태 확인 중"
    @Published var storageWatchInFlight = false

    let logStore = ScanLogStore()
    let projectRoot: URL
    private let normalReportName = "검사결과.html"
    private let shareReportName = "검사결과_공유용.html"

    init() {
        self.projectRoot = Self.detectProjectRoot()
        self.virusTotalEnabled = Self.loadVirusTotalEnabled(projectRoot: projectRoot)
        self.simulatorKeepNames = Self.loadSimulatorKeepNames()
        refreshExistingResults()
        Task { await refreshStorageWatchStatus() }
    }

    var isRunning: Bool { state == .running }
    var isBusy: Bool { isRunning || cleanupInFlight || storageWatchInFlight }
    var logText: String { logStore.text }
    var summary: ScanSummary? { content.summary }
    var macOSSecurity: MacOSSecurityStatus? { content.macOSSecurity }
    var storage: StorageSnapshot? { content.storage }
    var findings: [ScanFinding] { content.findings }
    var cpuRows: [CpuRow] { content.cpuRows }
    var networkRows: [NetworkRow] { content.networkRows }
    var autorunRows: [AutorunRow] { content.autorunRows }
    var recentInstalls: [RecentInstallRow] { content.recentInstalls }
    var normalReportURL: URL { projectRoot.appendingPathComponent(normalReportName) }
    var shareReportURL: URL { projectRoot.appendingPathComponent(shareReportName) }
    var hasNormalReport: Bool { FileManager.default.fileExists(atPath: normalReportURL.path) }
    var hasShareReport: Bool { FileManager.default.fileExists(atPath: shareReportURL.path) }
    var hasAnyReport: Bool { hasNormalReport || hasShareReport }
    var lastStorageScanAt: Date? { storageHistory.last?.capturedAt }
    var storageSnapshotIsStale: Bool {
        guard let lastStorageScanAt else { return true }
        return Date().timeIntervalSince(lastStorageScanAt) >= 30 * 60
    }
    var storageSnapshotAgeText: String {
        guard let lastStorageScanAt else { return "검사 기록 없음" }
        let seconds = max(0, Date().timeIntervalSince(lastStorageScanAt))
        if seconds < 60 { return "방금 검사" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전 검사" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))시간 전 검사" }
        return lastStorageScanAt.formatted(date: .abbreviated, time: .shortened)
    }

    func runScan() {
        guard !isBusy else { return }
        state = .running
        errorMessage = nil
        logStore.clear()
        appendLog("PC 건강검진 Mac Edition 시작")
        appendLog("프로젝트: \(projectRoot.path)")

        let root = projectRoot
        Task {
            let ok = await ScanPipeline.run(projectRoot: root) { line in
                Task { @MainActor in
                    self.appendLog(line)
                }
            }
            finishRun(success: ok)
        }
    }

    func finishRun(success: Bool) {
        refreshExistingResults()
        if success {
            state = .finished
            reportRevision += 1
            appendLog("완료: 일반 리포트와 공유용 리포트를 생성했습니다.")
        } else {
            state = .failed
            errorMessage = "검사 또는 리포트 생성 중 오류가 발생했습니다. 실행 로그를 확인하세요."
        }
    }

    private func refreshExistingResults() {
        parseScanResult()
        if hasNormalReport {
            selectedReportURL = normalReportURL
            selectedReportTitle = "일반 리포트"
        } else if hasShareReport {
            selectedReportURL = shareReportURL
            selectedReportTitle = "공유용 리포트"
        }
    }

    private func parseScanResult() {
        let url = projectRoot.appendingPathComponent("scan_result.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            content = .empty
            storageHistory = StorageHistoryStore.load()
            storageChange = StorageChangeSummary(entries: storageHistory)
            freeSpaceSamples = StorageHistoryStore.loadFreeSpaceSamples()
            return
        }
        content = ScanContent(root: root)
        recordStorageHistory(scanRoot: root, scanURL: url)
        freeSpaceSamples = StorageHistoryStore.loadFreeSpaceSamples()
    }

    private func recordStorageHistory(scanRoot: [String: Any], scanURL: URL) {
        guard let storage else {
            storageHistory = StorageHistoryStore.load()
            storageChange = StorageChangeSummary(entries: storageHistory)
            return
        }

        let sourceText = JsonRead.string(scanRoot, "scannedAt")
        let fileDate = (try? scanURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let capturedAt = Self.scanDate(from: sourceText) ?? fileDate
        let sourceID = sourceText.isEmpty
            ? String(Int(capturedAt.timeIntervalSince1970))
            : sourceText
        let entry = StorageHistoryEntry(sourceID: sourceID, capturedAt: capturedAt, storage: storage)

        do {
            storageHistory = try StorageHistoryStore.record(entry)
        } catch {
            storageHistory = StorageHistoryStore.load()
            appendLog("저장공간 이력을 기록하지 못했습니다: \(error.localizedDescription)")
        }
        storageChange = StorageChangeSummary(entries: storageHistory)
    }

    func appendLog(_ text: String) {
        logStore.append(text)
    }

    func replaceSimulatorKeepNames(with names: Set<String>) {
        simulatorKeepNames = names
    }

    private func refreshStorageWatchStatus() async {
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: ["./scripts/schedule.sh", "--status"],
            currentDirectory: projectRoot
        )
        let values = Self.protocolValues(result.output)
        storageWatchEnabled = result.status == 0 && values["enabled"] == "true"
        storageWatchDetail = storageWatchEnabled
            ? "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
            : "꺼짐 · 자동 삭제 없음"
        freeSpaceSamples = StorageHistoryStore.loadFreeSpaceSamples()
    }

    private static func scanDate(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    static func protocolValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                values[String(parts[0])] = String(parts[1])
            }
        }
        return values
    }

    private static func detectProjectRoot() -> URL {
        RuntimeWorkspace.resolve()
    }

    private static func loadVirusTotalEnabled(projectRoot: URL) -> Bool {
        let configURL = projectRoot.appendingPathComponent("data/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vt = root["virustotal"] as? [String: Any] else {
            return false
        }
        let enabled = vt["enabled"] as? Bool ?? false
        let apiKey = (vt["apiKey"] as? String ?? ProcessInfo.processInfo.environment["VT_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return enabled && !apiKey.isEmpty
    }

    private static var simulatorKeepURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PC Health Check/simulator-keep.txt")
    }

    private static func loadSimulatorKeepNames() -> Set<String> {
        guard let text = try? String(contentsOf: simulatorKeepURL, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    static func saveSimulatorKeepNames(_ names: Set<String>) throws {
        let url = simulatorKeepURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let text = names.sorted().joined(separator: "\n") + (names.isEmpty ? "" : "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
