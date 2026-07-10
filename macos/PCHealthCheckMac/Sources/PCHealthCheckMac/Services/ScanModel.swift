import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published var state: ScanState = .idle
    @Published var logText = ""
    @Published var summary: ScanSummary?
    @Published var macOSSecurity: MacOSSecurityStatus?
    @Published var storage: StorageSnapshot?
    @Published var findings: [ScanFinding] = []
    @Published var cpuRows: [CpuRow] = []
    @Published var networkRows: [NetworkRow] = []
    @Published var autorunRows: [AutorunRow] = []
    @Published var recentInstalls: [RecentInstallRow] = []
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
        logText = ""
        appendLog("PC 건강검진 Mac Edition 시작")
        appendLog("프로젝트: \(projectRoot.path)")

        let root = projectRoot
        Task {
            let ok = await Self.runPipeline(projectRoot: root) { line in
                Task { @MainActor in
                    self.appendLog(line)
                }
            }
            finishRun(success: ok)
        }
    }

    func showNormalReport() {
        guard hasNormalReport else { return }
        selectedReportURL = normalReportURL
        selectedReportTitle = "일반 리포트"
        reportRevision += 1
    }

    func showShareReport() {
        guard hasShareReport else { return }
        selectedReportURL = shareReportURL
        selectedReportTitle = "공유용 리포트"
        reportRevision += 1
    }

    func openNormalReportInBrowser() {
        guard hasNormalReport else { return }
        selectedReportURL = normalReportURL
        selectedReportTitle = "일반 리포트"
        NSWorkspace.shared.open(normalReportURL)
    }

    func openShareReportInBrowser() {
        guard hasShareReport else { return }
        selectedReportURL = shareReportURL
        selectedReportTitle = "공유용 리포트"
        NSWorkspace.shared.open(shareReportURL)
    }

    func openCurrentReportInBrowser() {
        guard let url = selectedReportURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealReportsInFinder() {
        let target = selectedReportURL ?? (hasNormalReport ? normalReportURL : projectRoot)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([projectRoot.appendingPathComponent("data/config.json")])
    }

    func openFullDiskAccessSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func revealStorageItem(_ item: StorageItem) {
        let url = URL(fileURLWithPath: item.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            errorMessage = "경로를 찾을 수 없어 클립보드에 복사했습니다: \(item.path)"
            copyToPasteboard(item.path)
        }
    }

    func copyGuide(for item: StorageItem) {
        copyToPasteboard(cleanupGuide(for: item))
    }

    func prepareCleanup(_ item: StorageItem) {
        guard item.canCleanup else { return }
        prepareCleanup(recipeID: item.cleanupID, label: item.label)
    }

    func prepareCleanup(_ device: SimulatorDevice) {
        guard !isSimulatorProtected(device), !device.cleanupID.isEmpty else { return }
        prepareCleanup(recipeID: device.cleanupID, label: device.name)
    }

    func isSimulatorProtected(_ device: SimulatorDevice) -> Bool {
        device.isBooted || simulatorKeepNames.contains(device.name)
    }

    func toggleSimulatorProtection(_ device: SimulatorDevice) {
        guard !device.isBooted else { return }
        if simulatorKeepNames.contains(device.name) {
            simulatorKeepNames.remove(device.name)
            appendLog("Simulator 보존 해제: \(device.name)")
        } else {
            simulatorKeepNames.insert(device.name)
            appendLog("Simulator 보존: \(device.name)")
        }
        do {
            try Self.saveSimulatorKeepNames(simulatorKeepNames)
        } catch {
            errorMessage = "Simulator 보존 목록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func prepareCleanup(recipeID: String, label: String) {
        guard !recipeID.isEmpty, !isBusy else { return }
        cleanupInFlight = true
        errorMessage = nil
        appendLog("정리 미리보기: \(label)")
        let root = projectRoot
        Task {
            let result = await Self.runProcessCapture(
                executable: "/bin/bash",
                arguments: ["./scripts/cleanup.sh", "--preview", recipeID],
                currentDirectory: root
            )
            cleanupInFlight = false
            guard let preview = CleanupPreview(protocolText: result.output) else {
                errorMessage = "정리 미리보기 결과를 읽지 못했습니다. 실행 로그를 확인하세요."
                appendLog("정리 미리보기 실패: \(result.status)")
                return
            }
            cleanupPreview = preview
            appendLog("미리보기: \(preview.statusText), 논리 크기 \(preview.estimatedText)")
        }
    }

    func executeCleanup(_ preview: CleanupPreview) {
        guard preview.canExecute, !isBusy, cleanupPreview?.recipeID == preview.recipeID else { return }
        cleanupInFlight = true
        errorMessage = nil
        appendLog("승인형 정리 실행: \(preview.label)")
        let root = projectRoot
        Task {
            let result = await Self.runProcessCapture(
                executable: "/bin/bash",
                arguments: ["./scripts/cleanup.sh", "--execute", preview.recipeID, "--owner-approved"],
                currentDirectory: root
            )
            guard let executed = CleanupPreview(protocolText: result.output) else {
                cleanupInFlight = false
                errorMessage = "정리 실행 결과를 읽지 못했습니다. 사용자 파일 정리는 다시 실행하지 말고 로그를 확인하세요."
                appendLog("정리 실행 결과 해석 실패: \(result.status)")
                return
            }
            if result.status == 0 && executed.isComplete {
                if executed.actionMode == "trash" {
                    appendLog("휴지통 이동 완료: \(executed.reclaimedText). 휴지통을 비운 뒤 실제 공간이 회수됩니다.")
                } else {
                    appendLog("정리 완료: 논리 크기 \(executed.reclaimedText), 실제 여유 변화 \(executed.physicalDeltaText)")
                }
                if !executed.receipt.isEmpty {
                    appendLog("영수증: \(executed.receipt)")
                }
                cleanupPreview = nil
                state = .running
                let ok = await Self.runPipeline(projectRoot: root) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
                cleanupInFlight = false
                finishRun(success: ok)
            } else {
                cleanupInFlight = false
                cleanupPreview = executed
                errorMessage = executed.blockedReason.isEmpty
                    ? "일부 항목을 정리하지 못했습니다. 영수증과 실행 로그를 확인하세요."
                    : executed.blockedReason
                appendLog("정리 중단: \(executed.statusText)")
            }
        }
    }

    func retryCleanupPreview(_ preview: CleanupPreview) {
        guard !isBusy, cleanupPreview?.recipeID == preview.recipeID else { return }
        prepareCleanup(recipeID: preview.recipeID, label: preview.label)
    }

    func dismissCleanupPreview() {
        guard !cleanupInFlight else { return }
        cleanupPreview = nil
    }

    func setStorageWatchEnabled(_ enabled: Bool) {
        guard !storageWatchInFlight, enabled != storageWatchEnabled else { return }
        storageWatchInFlight = true
        errorMessage = nil
        let root = projectRoot
        let command = enabled ? "--install" : "--uninstall"
        Task {
            let result = await Self.runProcessCapture(
                executable: "/bin/bash",
                arguments: ["./scripts/schedule.sh", command, "--owner-approved"],
                currentDirectory: root
            )
            storageWatchInFlight = false
            let values = Self.protocolValues(result.output)
            if result.status == 0, let value = values["enabled"] {
                storageWatchEnabled = value == "true"
                storageWatchDetail = storageWatchEnabled
                    ? "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
                    : "꺼짐 · 자동 삭제 없음"
                appendLog(storageWatchEnabled ? "저장공간 급감 감시를 켰습니다." : "저장공간 급감 감시를 껐습니다.")
            } else {
                errorMessage = "저장공간 감시 설정을 변경하지 못했습니다. 실행 로그를 확인하세요."
            }
        }
    }

    func copyCleanupGuide() {
        guard let storage else { return }
        let candidates = (storage.cleanupCandidates + storage.reviewCandidates + storage.developerToolchains).prefix(16)
        let lines = candidates.map { cleanupGuide(for: $0) }
        let text = """
        PC 건강검진 Mac Edition 정리 가이드

        원칙:
        - 삭제는 자동 실행하지 않으며, 앱의 고정 레시피도 미리보기와 개별 승인을 거칩니다.
        - Finder에서 위치를 확인하고, 실행 중인 앱/Xcode/Simulator/브라우저를 먼저 종료하세요.
        - Android SDK, Simulator runtime, 언어 toolchain은 프로젝트 요구 버전을 확인하기 전 통째 삭제하지 마세요.

        \(lines.joined(separator: "\n\n"))
        """
        copyToPasteboard(text)
    }

    func copyFullDiskAccessGuide() {
        let text = """
        PC 건강검진 Mac Edition - Full Disk Access 안내

        macOS는 Mail, Messages, Safari, 앱 컨테이너 같은 일부 영역을 개인정보 보호 설정으로 숨길 수 있습니다.
        리포트가 비어 보이거나 일부 앱 데이터가 빠진다면:

        1. 시스템 설정을 엽니다.
        2. 개인정보 보호 및 보안 > 전체 디스크 접근 권한으로 이동합니다.
        3. PC Health Check Mac 앱 또는 Terminal을 허용합니다.
        4. 앱을 다시 실행한 뒤 검사를 다시 돌립니다.

        이 권한은 읽기 범위를 넓히기 위한 것이며, PC Health Check는 삭제를 자동 실행하지 않습니다.
        """
        copyToPasteboard(text)
    }

    func clearLog() {
        logText = ""
    }

    private func cleanupGuide(for item: StorageItem) -> String {
        """
        \(item.label) (\(item.sizeText))
        경로: \(item.path)
        분류: \(item.kind)
        권장 확인: \(item.action)
        설명: \(item.note)
        """
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("클립보드에 복사했습니다.")
    }

    private func finishRun(success: Bool) {
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
            summary = nil
            macOSSecurity = nil
            storage = nil
            findings = []
            cpuRows = []
            networkRows = []
            autorunRows = []
            recentInstalls = []
            storageHistory = StorageHistoryStore.load()
            storageChange = StorageChangeSummary(entries: storageHistory)
            freeSpaceSamples = StorageHistoryStore.loadFreeSpaceSamples()
            return
        }
        summary = ScanSummary(json: root["summary"] as? [String: Any])
        let sections = root["sections"] as? [String: Any]
        macOSSecurity = MacOSSecurityStatus(json: sections?["macosSecurity"] as? [String: Any])
        storage = StorageSnapshot(json: sections?["storage"] as? [String: Any])
        findings = Self.array(root["findings"]).compactMap(ScanFinding.init(json:))
        cpuRows = Self.array(sections?["cpu"]).compactMap(CpuRow.init(json:))
        networkRows = Self.array(sections?["network"]).compactMap(NetworkRow.init(json:))
        autorunRows = Self.array(sections?["autoruns"]).compactMap(AutorunRow.init(json:))
        recentInstalls = Self.array(sections?["recentInstalls"]).compactMap(RecentInstallRow.init(json:))
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

    private func appendLog(_ text: String) {
        if logText.isEmpty {
            logText = text
        } else {
            logText += "\n" + text
        }
    }

    private static func runPipeline(projectRoot: URL, onOutput: @escaping @Sendable (String) -> Void) async -> Bool {
        let scanner = await runProcess(
            executable: "/bin/bash",
            arguments: ["./scripts/scanner.sh"],
            currentDirectory: projectRoot,
            environment: [
                "PCH_STORAGE_DU_TIMEOUT": "8",
                "PCH_STORAGE_TOTAL_DU_BUDGET": "32"
            ],
            onOutput: onOutput
        )
        guard scanner == 0 else {
            onOutput("scanner.sh 실패: \(scanner)")
            return false
        }

        let normal = await runReport(
            projectRoot: projectRoot,
            output: projectRoot.appendingPathComponent("검사결과.html"),
            redacted: false,
            onOutput: onOutput
        )
        guard normal == 0 else {
            onOutput("일반 리포트 생성 실패: \(normal)")
            return false
        }

        let share = await runReport(
            projectRoot: projectRoot,
            output: projectRoot.appendingPathComponent("검사결과_공유용.html"),
            redacted: true,
            onOutput: onOutput
        )
        if share != 0 {
            onOutput("공유용 리포트 생성 실패: \(share)")
            return false
        }
        return true
    }

    private static func runReport(
        projectRoot: URL,
        output: URL,
        redacted: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        var env = [
            "PCH_PROJECT_DIR": projectRoot.path,
            "PCH_REPORT_OUTPUT": output.path
        ]
        if redacted {
            env["PCH_REDACT"] = "true"
        }
        return await runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", projectRoot.appendingPathComponent("scripts/report.jxa.js").path],
            currentDirectory: projectRoot,
            environment: env,
            onOutput: onOutput
        )
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            var mergedEnvironment = ProcessInfo.processInfo.environment
            environment.forEach { mergedEnvironment[$0.key] = $0.value }
            process.environment = mergedEnvironment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let runState = ProcessRunState()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                text.split(whereSeparator: \.isNewline).forEach { onOutput(String($0)) }
            }

            process.terminationHandler = { terminated in
                pipe.fileHandleForReading.readabilityHandler = nil
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    text.split(whereSeparator: \.isNewline).forEach { onOutput(String($0)) }
                }
                runState.resume(continuation, returning: terminated.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                onOutput("실행 실패: \(executable) \(arguments.joined(separator: " "))")
                onOutput(error.localizedDescription)
                runState.resume(continuation, returning: -1)
            }
        }
    }

    private static func runProcessCapture(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) async -> CapturedProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.environment = ProcessInfo.processInfo.environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let runState = CaptureProcessRunState()

            process.terminationHandler = { terminated in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                runState.resume(
                    continuation,
                    returning: CapturedProcessResult(status: terminated.terminationStatus, output: output)
                )
            }

            do {
                try process.run()
            } catch {
                runState.resume(
                    continuation,
                    returning: CapturedProcessResult(status: -1, output: error.localizedDescription)
                )
            }
        }
    }

    private func refreshStorageWatchStatus() async {
        let result = await Self.runProcessCapture(
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

    private static func protocolValues(_ text: String) -> [String: String] {
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

    private static func saveSimulatorKeepNames(_ names: Set<String>) throws {
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

    private static func array(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }
}

private struct CapturedProcessResult: Sendable {
    let status: Int32
    let output: String
}

private final class CaptureProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<CapturedProcessResult, Never>,
        returning value: CapturedProcessResult
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}
