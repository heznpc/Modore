import Darwin
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
    @Published var cleanupIsExecuting = false
    @Published private(set) var storageHistory: [StorageHistoryEntry] = []
    @Published private(set) var storageChange: StorageChangeSummary?
    @Published private(set) var displayedStorageEntry: StorageHistoryEntry?
    @Published private(set) var freeSpaceSamples: [FreeSpaceSample] = []
    @Published private(set) var storageWatchPathEvents: [StorageWatchPathEvent] = []
    @Published private(set) var simulatorKeepUUIDs: Set<String> = []
    @Published private(set) var simulatorLegacyKeepEntries: Set<String> = []
    @Published var storageWatchEnabled = false
    @Published var storageWatchDetail = "상태 확인 중"
    @Published var storageWatchInFlight = false
    @Published private(set) var resultLoading = true

    let logStore = ScanLogStore()
    let projectRoot: URL
    private let normalReportName = "검사결과.html"
    private let shareReportName = "검사결과_공유용.html"
    private let terminationSafetyGate = AppTerminationSafetyGate()
    private var scanTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?

    init() {
        self.projectRoot = Self.detectProjectRoot()
        self.virusTotalEnabled = Self.loadVirusTotalEnabled(projectRoot: projectRoot)
        let keepState = SimulatorKeepStore.load()
        self.simulatorKeepUUIDs = keepState.uuids
        self.simulatorLegacyKeepEntries = keepState.legacyEntries
        Task { await refreshExistingResults() }
        Task { await refreshStorageWatchStatus() }
    }

    var isRunning: Bool { state == .running }
    var isBusy: Bool { isRunning || cleanupInFlight || storageWatchInFlight || resultLoading }
    var logText: String { logStore.text }
    var summary: ScanSummary? { content.summary }
    var collectionCoverage: CollectionCoverage? { content.collectionCoverage }
    var collectionIsIncomplete: Bool { collectionCoverage?.complete == false }
    var macOSSecurity: MacOSSecurityStatus? { content.macOSSecurity }
    var storage: StorageSnapshot? { content.storage }
    var findings: [ScanFinding] { content.findings }
    var securityFindings: [ScanFinding] { content.securityAttentionFindings }
    var storageAttentionFindings: [ScanFinding] { content.storageAttentionFindings }
    var cpuRows: [CpuRow] { content.cpuRows }
    var networkRows: [NetworkRow] { content.networkRows }
    var listeningPortRows: [ListeningPortRow] { content.listeningPortRows }
    var autorunRows: [AutorunRow] { content.autorunRows }
    var recentInstalls: [RecentInstallRow] { content.recentInstalls }
    var truncatedSecuritySections: [String] { content.truncatedSections }
    var attentionCpuRows: [CpuRow] { cpuRows.filter(\.requiresAttention) }
    var attentionNetworkRows: [NetworkRow] { networkRows.filter(\.requiresAttention) }
    var attentionListeningPortRows: [ListeningPortRow] {
        listeningPortRows.filter(\.requiresAttention)
    }
    var securityFindingCount: Int { content.securityAttentionCount }
    var securityAttentionCount: Int {
        securityFindingCount + (collectionCoverage?.requiredIssues.count ?? 0)
    }
    var securityHasDanger: Bool { content.securityHasDanger }
    var normalReportURL: URL { projectRoot.appendingPathComponent(normalReportName) }
    var shareReportURL: URL { projectRoot.appendingPathComponent(shareReportName) }
    var hasNormalReport: Bool { reportURLIsSafe(normalReportURL) }
    var hasShareReport: Bool { reportURLIsSafe(shareReportURL) }
    var hasAnyReport: Bool { hasNormalReport || hasShareReport }

    func reportURLIsSafe(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate == normalReportURL.standardizedFileURL
                || candidate == shareReportURL.standardizedFileURL else {
            return false
        }
        return Self.isSecureRegularFile(at: candidate, allowsRootOwner: false)
    }
    var lastStorageScanAt: Date? { displayedStorageEntry?.capturedAt }
    var newerStorageHistoryEntry: StorageHistoryEntry? {
        StorageHistoryStore.newestEntry(after: displayedStorageEntry, in: storageHistory)
    }
    var hasNewerStorageHistory: Bool { newerStorageHistoryEntry != nil }
    var hasUnresolvedSimulatorKeepEntries: Bool { !simulatorLegacyKeepEntries.isEmpty }
    var terminationSafetyState: AppTerminationSafetyState { terminationSafetyGate.state }
    var storageSnapshotIsStale: Bool {
        isStorageSnapshotStale(at: Date())
    }
    func isStorageSnapshotStale(at date: Date) -> Bool {
        guard let lastStorageScanAt else { return true }
        return date.timeIntervalSince(lastStorageScanAt) >= 30 * 60
    }
    func storageSnapshotNeedsRefresh(at date: Date = Date()) -> Bool {
        isStorageSnapshotStale(at: date) || hasNewerStorageHistory
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
        scanTask = Task {
            let ok = await ScanPipeline.run(projectRoot: root) { line in
                Task { @MainActor in
                    self.appendLog(line)
                }
            }
            guard !Task.isCancelled else {
                state = .idle
                appendLog("검사를 취소했습니다.")
                scanTask = nil
                return
            }
            await finishRun(success: ok)
            scanTask = nil
        }
    }

    func cancelScan() {
        guard isRunning else { return }
        scanTask?.cancel()
    }

    func cancelCleanupPreviewRequest() {
        guard cleanupInFlight, !cleanupIsExecuting else { return }
        cleanupTask?.cancel()
    }

    func beginDestructiveCleanupTransaction() {
        terminationSafetyGate.beginDestructiveTransaction()
        cleanupIsExecuting = true
    }

    func finishDestructiveCleanupTransaction() {
        cleanupIsExecuting = false
        terminationSafetyGate.finishDestructiveTransaction()
    }

    @discardableResult
    func deferApplicationTerminationUntilSafe(_ completion: @escaping () -> Void) -> Bool {
        terminationSafetyGate.deferTerminationUntilSafe(completion)
    }

    func finishRun(success: Bool) async {
        await refreshExistingResults()
        if success {
            state = .finished
            reportRevision += 1
            appendLog("완료: 일반 리포트와 공유용 리포트를 생성했습니다.")
        } else {
            state = .failed
            if selectedReportURL != nil {
                selectedReportTitle = "이전 리포트 (이번 검사 아님)"
            }
            errorMessage = "이번 검사 또는 리포트 생성 중 오류가 발생했습니다. 표시된 이전 결과를 새 결과로 해석하지 마세요."
        }
    }

    private func refreshExistingResults() async {
        resultLoading = true
        let root = projectRoot
        let loaded = await Task.detached(priority: .utility) {
            ScanResultLoader.load(projectRoot: root)
        }.value
        content = loaded.content
        if let completedScanVirusTotalEnabled = loaded.content.virusTotalEnabled {
            virusTotalEnabled = completedScanVirusTotalEnabled
        }
        reconcileLegacySimulatorKeepEntries(with: loaded.content.storage?.simulatorDevices ?? [])
        storageHistory = loaded.storageHistory
        displayedStorageEntry = loaded.displayedStorageEntry
        storageChange = loaded.storageChange
        freeSpaceSamples = loaded.freeSpaceSamples
        await refreshStorageWatchEvidence()
        if let diagnostic = loaded.diagnostic {
            appendLog(diagnostic)
        }
        if hasNormalReport {
            selectedReportURL = normalReportURL
            selectedReportTitle = "일반 리포트"
        } else if hasShareReport {
            selectedReportURL = shareReportURL
            selectedReportTitle = "공유용 리포트"
        }
        resultLoading = false
    }

    func refreshStorageWatchEvidence() async {
        let snapshots = await Task.detached(priority: .utility) {
            StorageWatchSnapshotStore.load()
        }.value
        storageWatchPathEvents = StorageWatchSnapshotStore.events(from: snapshots)
    }

    func appendLog(_ text: String) {
        logStore.append(text)
    }

    func replaceSimulatorKeepUUIDs(with uuids: Set<String>) {
        simulatorKeepUUIDs = uuids
    }

    private func reconcileLegacySimulatorKeepEntries(with devices: [SimulatorDevice]) {
        guard !simulatorLegacyKeepEntries.isEmpty else { return }
        let migration = SimulatorKeepState(
            uuids: simulatorKeepUUIDs,
            legacyEntries: simulatorLegacyKeepEntries
        ).resolvingLegacyEntries(with: devices)
        simulatorKeepUUIDs = migration.uuids

        guard migration.unresolvedEntries.isEmpty else {
            simulatorLegacyKeepEntries = migration.unresolvedEntries
            appendLog("기존 Simulator 보존 항목 \(migration.unresolvedEntries.count)개를 UUID로 확인하지 못해 모든 기기 삭제를 차단했습니다.")
            return
        }

        do {
            try SimulatorKeepStore.save(migration.uuids)
            simulatorLegacyKeepEntries = []
            appendLog("기존 Simulator 이름 보존 목록을 UUID 기준으로 안전하게 전환했습니다.")
        } catch {
            appendLog("기존 Simulator 보존 목록을 전환하지 못해 모든 기기 삭제를 차단했습니다: \(error.localizedDescription)")
        }
    }

    private func refreshStorageWatchStatus() async {
        let status = await StorageWatchService.status(projectRoot: projectRoot)
        storageWatchEnabled = status.enabled
        storageWatchDetail = status.detail
        if let samples = status.freeSpaceSamples {
            freeSpaceSamples = samples
        }
    }

    private nonisolated static func isSecureRegularFile(
        at url: URL,
        allowsRootOwner: Bool
    ) -> Bool {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        let allowedOwner = value.st_uid == Darwin.geteuid()
            || (allowsRootOwner && value.st_uid == 0)
        return status == 0
            && value.st_mode & S_IFMT == S_IFREG
            && allowedOwner
            && value.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }

    private nonisolated static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try SecureLocalFileIO.boundedRead(from: url, maximumBytes: maximumBytes)
    }

    private static func detectProjectRoot() -> URL {
        RuntimeWorkspace.resolve()
    }

    private static func loadVirusTotalEnabled(projectRoot: URL) -> Bool {
        let externalConfigURL = RuntimeWorkspace.userConfigURL()
        let configURL = FileManager.default.fileExists(atPath: externalConfigURL.path)
            ? externalConfigURL
            : projectRoot.appendingPathComponent("data/config.json")
        guard let data = try? boundedRegularFileData(
                at: configURL,
                maximumBytes: 1_048_576
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vt = root["virustotal"] as? [String: Any] else {
            return false
        }
        let enabled = vt["enabled"] as? Bool ?? false
        let configuredKey = (vt["apiKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentKey = (ProcessInfo.processInfo.environment["VT_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty ? environmentKey : configuredKey
        return enabled && !apiKey.isEmpty
    }
}
