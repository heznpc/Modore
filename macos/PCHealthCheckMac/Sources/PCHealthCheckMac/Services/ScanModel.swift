import Darwin
import CryptoKit
import Foundation
import SwiftUI

enum StorageWatchRuntimeState: Equatable, Sendable {
    case absent
    case current
    case stale
}

enum AppTerminationSafetyState: Equatable, Sendable {
    case safe
    case destructiveCleanupInProgress
}

@MainActor
final class AppTerminationSafetyGate {
    private var activeDestructiveTransactions = 0
    private var pendingTerminationReplies: [() -> Void] = []

    var state: AppTerminationSafetyState {
        activeDestructiveTransactions == 0 ? .safe : .destructiveCleanupInProgress
    }

    func beginDestructiveTransaction() {
        activeDestructiveTransactions += 1
    }

    func finishDestructiveTransaction() {
        guard activeDestructiveTransactions > 0 else { return }
        activeDestructiveTransactions -= 1
        guard activeDestructiveTransactions == 0 else { return }
        let replies = pendingTerminationReplies
        pendingTerminationReplies.removeAll(keepingCapacity: false)
        replies.forEach { $0() }
    }

    /// Returns true when termination must be delayed. The completion is never
    /// associated with a timeout or cancellation; it runs only after every
    /// destructive transaction reports completion.
    @discardableResult
    func deferTerminationUntilSafe(_ completion: @escaping () -> Void) -> Bool {
        guard activeDestructiveTransactions > 0 else { return false }
        pendingTerminationReplies.append(completion)
        return true
    }
}

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
        let keepState = Self.loadSimulatorKeepState()
        self.simulatorKeepUUIDs = keepState.uuids
        self.simulatorLegacyKeepEntries = keepState.legacyEntries
        Task { await refreshExistingResults() }
        Task { await refreshStorageWatchStatus() }
    }

    var isRunning: Bool { state == .running }
    var isBusy: Bool { isRunning || cleanupInFlight || storageWatchInFlight || resultLoading }
    var logText: String { logStore.text }
    var summary: ScanSummary? { content.summary }
    var macOSSecurity: MacOSSecurityStatus? { content.macOSSecurity }
    var storage: StorageSnapshot? { content.storage }
    var findings: [ScanFinding] { content.findings }
    var cpuRows: [CpuRow] { content.cpuRows }
    var networkRows: [NetworkRow] { content.networkRows }
    var autorunRows: [AutorunRow] { content.autorunRows }
    var recentInstalls: [RecentInstallRow] { content.recentInstalls }
    var truncatedSecuritySections: [String] { content.truncatedSections }
    var attentionCpuRows: [CpuRow] { cpuRows.filter(\.requiresAttention) }
    var attentionNetworkRows: [NetworkRow] { networkRows.filter(\.requiresAttention) }
    var securityAttentionCount: Int { summary?.attentionCount ?? 0 }
    var securityHasDanger: Bool { summary?.hasDanger ?? false }
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
        reconcileLegacySimulatorKeepEntries(with: loaded.content.storage?.simulatorDevices ?? [])
        storageHistory = loaded.storageHistory
        displayedStorageEntry = loaded.displayedStorageEntry
        storageChange = loaded.storageChange
        freeSpaceSamples = loaded.freeSpaceSamples
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
            try Self.saveSimulatorKeepUUIDs(migration.uuids)
            simulatorLegacyKeepEntries = []
            appendLog("기존 Simulator 이름 보존 목록을 UUID 기준으로 안전하게 전환했습니다.")
        } catch {
            appendLog("기존 Simulator 보존 목록을 전환하지 못해 모든 기기 삭제를 차단했습니다: \(error.localizedDescription)")
        }
    }

    private func refreshStorageWatchStatus() async {
        let root = projectRoot
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: root)
        }).value else {
            storageWatchEnabled = false
            storageWatchDetail = "서명된 감시 런타임을 확인할 수 없음"
            freeSpaceSamples = await Task.detached(priority: .utility) {
                StorageHistoryStore.loadFreeSpaceSamples()
            }.value
            return
        }
        guard let invocation = execution.pinnedInvocation(
            relativePath: "scripts/schedule.sh",
            name: "schedule"
        ) else {
            storageWatchEnabled = false
            storageWatchDetail = "봉인한 감시 설정 프로그램을 확인할 수 없음"
            return
        }
        guard let watcherHash = execution.sealedSHA256(
            relativePath: "scripts/storage_watch.sh"
        ) else {
            storageWatchEnabled = false
            storageWatchDetail = "봉인한 저장공간 감시 프로그램을 확인할 수 없음"
            return
        }
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [invocation.argument, "--status"],
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: invocation.files,
            environment: [
                "PCH_STORAGE_WATCH_SCRIPT": execution.storageWatchScriptURL.path,
                "PCH_STORAGE_WATCH_SHA256": watcherHash,
            ]
        )
        let values = Self.protocolValues(result.output)
        let harnessEnabled = result.status == 0 && values["enabled"] == "true"
        let runtimeState = Self.storageWatchRuntimeState(
            protocolValues: values,
            expectedWatcherURL: execution.storageWatchScriptURL,
            expectedWatcherSHA256: watcherHash
        )
        storageWatchEnabled = harnessEnabled && runtimeState == .current
        if runtimeState == .stale {
            storageWatchDetail = "안전하지 않은 이전 감시 plist가 남았습니다. 감시를 껐다 다시 켜 제거하세요."
        } else {
            storageWatchDetail = storageWatchEnabled
                ? "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
                : "꺼짐 · 자동 삭제 없음"
        }
        freeSpaceSamples = await Task.detached(priority: .utility) {
            StorageHistoryStore.loadFreeSpaceSamples()
        }.value
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

    nonisolated static func storageWatchRuntimeState(
        protocolValues: [String: String],
        expectedWatcherURL: URL,
        expectedWatcherSHA256: String? = nil,
        expectedHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> StorageWatchRuntimeState {
        guard let plistPath = protocolValues["plist"], plistPath.hasPrefix("/") else {
            return .stale
        }
        if protocolValues["loaded"] == "true",
           protocolValues["loadedDefinitionCurrent"] != "true" {
            return .stale
        }
        let plistURL = URL(fileURLWithPath: plistPath)
        let expectedPlistURL = expectedHomeURL
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("me.heznpc.pchealthcheck.storage-watch.plist")
        guard let watcherHash = expectedWatcherSHA256 ?? secureSHA256(
            at: expectedWatcherURL,
            maximumBytes: 1_048_576
        ), watcherHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return .stale
        }
        let expectedArguments = [
            "/usr/bin/env",
            "-i",
            "HOME=\(expectedHomeURL.standardizedFileURL.path)",
            "PATH=\(LocalProcessRunner.safeSystemPath)",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
            "/bin/bash",
            "-p",
            "-c",
            storageWatchWrapper,
            "--",
            watcherHash,
            expectedWatcherURL.standardizedFileURL.path,
        ]
        let expectedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "RunAtLoad",
            "StandardErrorPath",
            "StandardOutPath",
            "StartInterval",
        ]
        guard pathEntryExists(plistURL) else { return .absent }
        guard plistURL.standardizedFileURL == expectedPlistURL.standardizedFileURL,
              isSecureRegularFile(at: expectedWatcherURL, allowsRootOwner: true),
              secureSHA256(at: expectedWatcherURL, maximumBytes: 1_048_576) == watcherHash,
              isSecureRegularFile(at: plistURL, allowsRootOwner: false),
              !pathContainsSymbolicLink(plistURL.deletingLastPathComponent()),
              !pathContainsSymbolicLink(expectedWatcherURL.deletingLastPathComponent()),
              let data = try? boundedRegularFileData(
                at: plistURL,
                maximumBytes: 65_536
              ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              Set(dictionary.keys) == expectedKeys,
              dictionary["Label"] as? String == "me.heznpc.pchealthcheck.storage-watch",
              let arguments = dictionary["ProgramArguments"] as? [String],
              arguments == expectedArguments,
              (dictionary["StartInterval"] as? NSNumber)?.intValue == 3600,
              (dictionary["RunAtLoad"] as? NSNumber)?.boolValue == true,
              dictionary["StandardOutPath"] as? String == "/dev/null",
              dictionary["StandardErrorPath"] as? String == "/dev/null" else {
            return .stale
        }
        return .current
    }

    private nonisolated static func pathEntryExists(_ url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &value) == 0
        }
    }

    private nonisolated static func isRegularFileWithoutSymlink(at url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, Darwin.lstat(path, &value) == 0 else { return false }
            return value.st_mode & S_IFMT == S_IFREG
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

    private nonisolated static func pathContainsSymbolicLink(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { return true }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if current.path == "/var" || current.path == "/tmp" {
                continue
            }
            var value = stat()
            let status = current.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &value)
            }
            if status == 0, value.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private nonisolated static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try SecureLocalFileIO.boundedRead(from: url, maximumBytes: maximumBytes)
    }

    nonisolated static let storageWatchWrapper = #"set -u; script="$2"; expected="$1"; [[ -f "$script" && ! -L "$script" ]] || exit 78; size=$(/usr/bin/stat -f "%z" "$script") || exit 78; [[ "$size" -le 1048576 ]] || exit 78; payload=$(/usr/bin/base64 < "$script") || exit 78; digest=$(/usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /usr/bin/shasum -a 256) || exit 78; actual="${digest%% *}"; [[ "$actual" == "$expected" ]] || exit 78; /usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /bin/bash -p"#

    private nonisolated static func secureSHA256(
        at url: URL,
        maximumBytes: Int
    ) -> String? {
        guard let data = try? boundedRegularFileData(at: url, maximumBytes: maximumBytes) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private static var simulatorKeepURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PC Health Check/simulator-keep.txt")
    }

    private static func loadSimulatorKeepState() -> SimulatorKeepState {
        guard let data = try? boundedRegularFileData(
                at: simulatorKeepURL,
                maximumBytes: 65_536
              ),
              let text = String(data: data, encoding: .utf8) else {
            return SimulatorKeepState(uuids: [], legacyEntries: [])
        }
        let entries = Set(text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let uuids = Set(entries.map { $0.uppercased() }.filter(Self.isSimulatorUUID))
        let legacyEntries = entries.filter { !Self.isSimulatorUUID($0.uppercased()) }
        return SimulatorKeepState(uuids: uuids, legacyEntries: legacyEntries)
    }

    static func saveSimulatorKeepUUIDs(_ uuids: Set<String>) throws {
        let url = simulatorKeepURL
        let normalized = Set(uuids.map { $0.uppercased() }.filter(Self.isSimulatorUUID))
        let text = normalized.sorted().joined(separator: "\n") + (normalized.isEmpty ? "" : "\n")
        try SecureLocalFileIO.atomicWrite(
            Data(text.utf8),
            to: url,
            permissions: 0o600
        )
    }

    private static func isSimulatorUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}

struct LoadedScanResult: @unchecked Sendable {
    let content: ScanContent
    let storageHistory: [StorageHistoryEntry]
    let displayedStorageEntry: StorageHistoryEntry?
    let storageChange: StorageChangeSummary?
    let freeSpaceSamples: [FreeSpaceSample]
    let diagnostic: String?
}

enum ScanResultLoader {
    static let maximumScanResultBytes = 32 * 1_024 * 1_024

    static func load(
        projectRoot: URL,
        historyURL: URL = StorageHistoryStore.historyURL,
        sampleURL: URL = StorageHistoryStore.sampleURL
    ) -> LoadedScanResult {
        let scanURL = projectRoot.appendingPathComponent("scan_result.json")
        let scanParentIdentity = FilesystemIdentity.directory(at: projectRoot)
        let existingHistory = StorageHistoryStore.load(from: historyURL)
        let samples = StorageHistoryStore.loadFreeSpaceSamples(from: sampleURL)
        guard FileManager.default.fileExists(atPath: scanURL.path) else {
            return LoadedScanResult(
                content: .empty,
                storageHistory: existingHistory,
                displayedStorageEntry: nil,
                storageChange: nil,
                freeSpaceSamples: samples,
                diagnostic: nil
            )
        }

        let data: Data
        do {
            guard let scanParentIdentity else { throw ScanResultLoaderError.unreadable }
            data = try boundedData(
                contentsOf: scanURL,
                maximumBytes: maximumScanResultBytes,
                expectedParentIdentity: scanParentIdentity
            )
        } catch ScanResultLoaderError.tooLarge {
            return emptyResult(
                history: existingHistory,
                samples: samples,
                diagnostic: "검사 결과가 \(maximumScanResultBytes / 1_048_576)MB 제한을 넘어 읽지 않았습니다. 다시 검사하세요."
            )
        } catch {
            return emptyResult(
                history: existingHistory,
                samples: samples,
                diagnostic: "검사 결과를 읽지 못했습니다: \(error.localizedDescription)"
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return emptyResult(
                history: existingHistory,
                samples: samples,
                diagnostic: "검사 결과 JSON이 올바르지 않아 표시하지 않았습니다. 다시 검사하세요."
            )
        }

        let content = ScanContent(root: root)
        guard let storage = content.storage else {
            return LoadedScanResult(
                content: content,
                storageHistory: existingHistory,
                displayedStorageEntry: nil,
                storageChange: nil,
                freeSpaceSamples: samples,
                diagnostic: nil
            )
        }

        let sourceText = JsonRead.string(root, "scannedAt")
        let fileDate = (try? scanURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let capturedAt = scanDate(from: sourceText) ?? fileDate
        let sourceID = sourceText.isEmpty
            ? String(Int(capturedAt.timeIntervalSince1970))
            : sourceText
        let entry = StorageHistoryEntry(
            sourceID: sourceID,
            capturedAt: capturedAt,
            storage: storage
        )

        do {
            let history = try StorageHistoryStore.record(entry, at: historyURL)
            return LoadedScanResult(
                content: content,
                storageHistory: history,
                displayedStorageEntry: entry,
                storageChange: StorageHistoryStore.changeSummary(endingAt: sourceID, in: history),
                freeSpaceSamples: samples,
                diagnostic: nil
            )
        } catch {
            return LoadedScanResult(
                content: content,
                storageHistory: existingHistory,
                displayedStorageEntry: entry,
                storageChange: StorageHistoryStore.changeSummary(
                    endingAt: sourceID,
                    in: existingHistory + [entry]
                ),
                freeSpaceSamples: samples,
                diagnostic: "저장공간 이력을 기록하지 못했습니다: \(error.localizedDescription)"
            )
        }
    }

    static func boundedData(
        contentsOf url: URL,
        maximumBytes: Int,
        expectedParentIdentity: FilesystemIdentity? = nil
    ) throws -> Data {
        do {
            return try SecureLocalFileIO.boundedRead(
                from: url,
                maximumBytes: maximumBytes,
                requireCurrentOwner: true,
                expectedParentIdentity: expectedParentIdentity
            )
        } catch let error as NSError where error.code == Int(EFBIG) {
            throw ScanResultLoaderError.tooLarge
        } catch {
            throw ScanResultLoaderError.unreadable
        }
    }

    private static func emptyResult(
        history: [StorageHistoryEntry],
        samples: [FreeSpaceSample],
        diagnostic: String
    ) -> LoadedScanResult {
        LoadedScanResult(
            content: .empty,
            storageHistory: history,
            displayedStorageEntry: nil,
            storageChange: nil,
            freeSpaceSamples: samples,
            diagnostic: diagnostic
        )
    }

    private static func scanDate(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

enum ScanResultLoaderError: Error {
    case tooLarge
    case unreadable
}

struct SimulatorKeepMigration: Equatable {
    let uuids: Set<String>
    let unresolvedEntries: Set<String>
}

struct SimulatorKeepState: Equatable {
    let uuids: Set<String>
    let legacyEntries: Set<String>

    func resolvingLegacyEntries(with devices: [SimulatorDevice]) -> SimulatorKeepMigration {
        var resolvedUUIDs = uuids
        var unresolved = legacyEntries
        for entry in legacyEntries {
            let matches = devices.filter { $0.name == entry }
            guard !matches.isEmpty else { continue }
            matches.forEach { resolvedUUIDs.insert($0.uuid.uppercased()) }
            unresolved.remove(entry)
        }
        return SimulatorKeepMigration(uuids: resolvedUUIDs, unresolvedEntries: unresolved)
    }
}
