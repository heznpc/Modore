import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published var state: ScanState = .idle
    @Published var logText = ""
    @Published var summary: ScanSummary?
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

    let projectRoot: URL
    private let normalReportName = "검사결과.html"
    private let shareReportName = "검사결과_공유용.html"

    init() {
        self.projectRoot = Self.detectProjectRoot()
        self.virusTotalEnabled = Self.loadVirusTotalEnabled(projectRoot: projectRoot)
        refreshExistingResults()
    }

    var isRunning: Bool { state == .running }
    var normalReportURL: URL { projectRoot.appendingPathComponent(normalReportName) }
    var shareReportURL: URL { projectRoot.appendingPathComponent(shareReportName) }
    var hasNormalReport: Bool { FileManager.default.fileExists(atPath: normalReportURL.path) }
    var hasShareReport: Bool { FileManager.default.fileExists(atPath: shareReportURL.path) }
    var hasAnyReport: Bool { hasNormalReport || hasShareReport }

    func runScan() {
        guard !isRunning else { return }
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

    func copyCleanupGuide() {
        guard let storage else { return }
        let candidates = (storage.cleanupCandidates + storage.developerToolchains).prefix(12)
        let lines = candidates.map { cleanupGuide(for: $0) }
        let text = """
        PC 건강검진 Mac Edition 정리 가이드

        원칙:
        - 삭제는 자동 실행하지 않습니다.
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
            showNormalReport()
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
            storage = nil
            findings = []
            cpuRows = []
            networkRows = []
            autorunRows = []
            recentInstalls = []
            return
        }
        summary = ScanSummary(json: root["summary"] as? [String: Any])
        let sections = root["sections"] as? [String: Any]
        storage = StorageSnapshot(json: sections?["storage"] as? [String: Any])
        findings = Self.array(root["findings"]).compactMap(ScanFinding.init(json:))
        cpuRows = Self.array(sections?["cpu"]).compactMap(CpuRow.init(json:))
        networkRows = Self.array(sections?["network"]).compactMap(NetworkRow.init(json:))
        autorunRows = Self.array(sections?["autoruns"]).compactMap(AutorunRow.init(json:))
        recentInstalls = Self.array(sections?["recentInstalls"]).compactMap(RecentInstallRow.init(json:))
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
                "PCH_STORAGE_DU_TIMEOUT": "4",
                "PCH_STORAGE_TOTAL_DU_BUDGET": "24"
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

    private static func detectProjectRoot() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let path = env["PCH_PROJECT_DIR"], hasScanner(at: URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let marker = resourceURL.appendingPathComponent("project-root.txt")
            if let text = try? String(contentsOf: marker, encoding: .utf8) {
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if hasScanner(at: URL(fileURLWithPath: path)) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        var current = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            if hasScanner(at: current) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: fm.currentDirectoryPath)
    }

    private static func hasScanner(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/scanner.sh").path)
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

    private static func array(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }
}
