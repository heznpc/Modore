import AppKit

import Foundation
import UserNotifications

struct AutomaticCachePolicy {
    static let recipes = ["npm_download_cache", "pip_cache", "homebrew_cache"]
    static func ownsStorageNotice(enabled: Bool, appRunning: Bool, free: Int64?) -> Bool {
        guard enabled, appRunning, let free else { return false }
        return free >= 3 * 1_073_741_824
    }

    static func shouldNotify(_ report: AutomaticCacheReport, previous: AutomaticCacheReport?) -> Bool {
        if !report.receipts.isEmpty { return true }
        guard let previous else { return true }
        if report.finished != previous.finished { return true }
        let meaningful = { (rows: [String]) in rows.filter { !$0.hasPrefix("경로별 원인 분석 저장:") } }
        if meaningful(report.outcomes) != meaningful(previous.outcomes) { return true }
        return HealthNoticePolicy.storageLevel(report.after) >= 4
            && HealthNoticePolicy.storageLevel(previous.after) < 4
    }

    /// The collector orders rows by file age/size, not by measured growth.
    /// Keep those candidates separate so unchanged large trees cannot bury a
    /// newly growing swap volume or cache in the three-line notification.
    static func evidenceLines(_ rows: [[String: Any]]) -> [String] {
        let growth = rows.filter { ($0["recentDeltaBytes"] as? Int64 ?? 0) > 0 }
            .sorted { ($0["recentDeltaBytes"] as? Int64 ?? 0) > ($1["recentDeltaBytes"] as? Int64 ?? 0) }
        var lines = growth.prefix(3).map { row in
            "\(row["label"] as? String ?? "경로") 최근 실측 증가 +\(HealthSnapshot.bytes(row["recentDeltaBytes"] as? Int64))"
        }
        if lines.isEmpty { lines.append("비교 가능한 경로에서 최근 증가가 확인되지 않았습니다.") }
        let unmeasured = rows.filter { $0["recentDeltaBytes"] as? Int64 == nil }
            .compactMap { $0["label"] as? String }
        if !unmeasured.isEmpty {
            lines.append("증가량 미확인: " + unmeasured.joined(separator: ", "))
        }
        return lines
    }

    static let target: Int64 = 20 * 1_073_741_824

    static func shouldRun(enabled: Bool, free: Int64?, lastRun: Date?, now: Date) -> Bool {
        guard enabled, let free, free < target else { return false }
        return lastRun.map { now.timeIntervalSince($0) >= 1800 } ?? true
    }
}

struct AutomaticCacheReport: Codable {
    var id = UUID()
    var date: Date
    var before: Int64
    var after: Int64?
    var evidence: String
    var outcomes: [String] = []
    var receipts: [String] = []
    var attempted: [String: Date] = [:]
    var analysisAt: Date?
    var finished = false
}

/// Only explicit standing consent authorizes these fixed, regenerable caches.
/// All mutations use the existing preview, process check, staging and receipt engine.
@MainActor
final class AutomaticCacheRecovery: ObservableObject {
    @Published private(set) var detail = "자동 관리 대기 중"
    @Published private(set) var running = false
    private let defaults: UserDefaults
    private let reportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Modore/automatic-cache-recovery.json")
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "automaticSafeCacheRecovery") }
    }
    private var last: AutomaticCacheReport?
    private var readable = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "automaticSafeCacheRecovery")
        if FileManager.default.fileExists(atPath: reportURL.path) {
            do {
                last = try JSONDecoder().decode(AutomaticCacheReport.self, from: Data(contentsOf: reportURL))
                detail = last?.finished == true ? Self.summary(last!) : "이전 자동 관리가 중단됐습니다. 처리 기록을 확인하세요."
            } catch { readable = false; detail = "자동 관리 기록을 읽지 못해 실행을 보류했습니다." }
        }
    }

    var isDue: Bool {
        readable && AutomaticCachePolicy.shouldRun(enabled: enabled, free: Self.freeSpace(),
            lastRun: last?.date, now: Date())
    }

    static func freeSpace() -> Int64? {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (values?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static func summary(_ report: AutomaticCacheReport) -> String {
        guard let after = report.after else { return "자동 관리 결과의 여유 공간을 확인하지 못했습니다." }
        let delta = after - report.before
        return "자동 관리 후 여유 \(HealthSnapshot.bytes(after)) · 실제 변화 \(delta >= 0 ? "+" : "−")\(HealthSnapshot.bytes(abs(delta)))"
    }

    private func save(_ report: AutomaticCacheReport) throws {
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(report)
        let archive = reportURL.deletingLastPathComponent().appendingPathComponent("automatic-cache-recovery-history", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = archive.appendingPathComponent(report.id.uuidString + ".json")
        try data.write(to: record, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        try data.write(to: reportURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        last = report
    }

    func revealReport() { NSWorkspace.shared.open(reportURL) }

    func runIfNeeded(model: ScanModel, snapshot: HealthSnapshot?, requestedNow: Bool = false) async {
        guard !running else { return }
        // UI and scheduled headless launches share the same intent and lease.
        // Reload under the lease: another process may have recovered space since init.
        guard case .acquired(let lease) = AppInstanceCoordinator.acquireLease(
            at: reportURL.deletingLastPathComponent().appendingPathComponent("automatic-recovery-lock")) else { return }
        defer { withExtendedLifetime(lease) {} }
        if FileManager.default.fileExists(atPath: reportURL.path) {
            do {
                last = try JSONDecoder().decode(AutomaticCacheReport.self, from: Data(contentsOf: reportURL))
                readable = true
                if let last { detail = last.finished ? Self.summary(last) : "이전 자동 관리가 중단됐습니다. 처리 기록을 확인하세요." }
            } catch { readable = false }
        }
        enabled = defaults.bool(forKey: "automaticSafeCacheRecovery")
        guard readable, !model.cleanupInFlight, !model.isRunning,
              !model.applicationTerminationStarted,
              AutomaticCachePolicy.shouldRun(enabled: enabled, free: Self.freeSpace(), lastRun: requestedNow ? nil : last?.date, now: Date()),
              let before = Self.freeSpace() else { return }
        running = true
        model.cleanupInFlight = true
        model.beginDestructiveCleanupTransaction()
        defer {
            running = false
            model.cleanupInFlight = false
            model.finishDestructiveCleanupTransaction()
        }
        let fresh = snapshot.flatMap { Date().timeIntervalSince($0.date) < 60 ? $0 : nil }
        let top = fresh.flatMap { $0.cpuAvailable ? $0 : nil }?.processes.sorted { $0.cpu > $1.cpu }.prefix(3)
            .map { "\($0.name) \(Int($0.cpu))%" }.joined(separator: ", ") ?? "CPU 원인 미확인"
        let previousReport = last
        var report = AutomaticCacheReport(date: Date(), before: before,
            evidence: "\(fresh?.summary ?? "최근 상태 표본 없음") · CPU 상위: \(top). 캐시 점유는 회수 후보이며 공간 감소 원인으로 확정한 값은 아닙니다.",
            attempted: last?.attempted ?? [:], analysisAt: last?.analysisAt)
        detail = "사용 중인 작업을 확인하고 다운로드 캐시를 분석하는 중"
        do {
            // Persist intent first: an app restart cannot immediately repeat deletion.
            try save(report)
            guard let context = await CleanupExecutionService.prepare(projectRoot: model.projectRoot) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for recipe in AutomaticCachePolicy.recipes {
                guard enabled, defaults.bool(forKey: "automaticSafeCacheRecovery"), !Task.isCancelled, !model.applicationTerminationStarted,
                      let available = Self.freeSpace(), available < AutomaticCachePolicy.target else { break }
                // Avoid repeatedly deleting a cache that a workflow is rebuilding.
                if let attempted = report.attempted[recipe], Date().timeIntervalSince(attempted) < 86400 {
                    report.outcomes.append("\(recipe): 최근 처리한 캐시로 보존"); continue
                }
                let result = await CleanupExecutionService.preview(recipeID: recipe, using: context)
                guard let preview = CleanupPreview(protocolText: result.output), result.endState == .exited,
                      preview.recipeID == recipe, preview.operation == "preview" else {
                    report.outcomes.append("\(recipe): 분석 실패 · 보존"); continue
                }
                guard result.succeeded, preview.canExecute else {
                    report.outcomes.append("\(preview.label): \(preview.blockedReason.isEmpty ? preview.statusText : preview.blockedReason)"); continue
                }
                guard let size = preview.estimatedBytes, size >= 16 * 1_048_576 else {
                    report.outcomes.append("\(preview.label): 작은 캐시로 보존"); continue
                }
                guard enabled, defaults.bool(forKey: "automaticSafeCacheRecovery"), preview.approvalIsFresh(), model.persistCleanupMutationIntent() else { break }
                report.attempted[recipe] = Date()
                report.outcomes.append("\(preview.label): \(HealthSnapshot.bytes(size)) 처리 시작")
                try save(report)
                let execution = await CleanupExecutionService.execute(preview, using: context)
                guard let execution else {
                    // No process launched (e.g. foreground cleanup owns the lease).
                    // Do not turn contention into a full day of suppressed retries.
                    report.attempted.removeValue(forKey: recipe)
                    report.outcomes.append("\(recipe): 다른 정리 또는 승인 검증으로 실행 보류 · 다음 점검에서 재확인")
                    try save(report)
                    break
                }
                guard let outcome = CleanupPreview(protocolText: execution.output),
                      outcome.recipeID == recipe else {
                    report.outcomes.append("\(recipe): 실행 결과 미확인 · 재실행 중단"); break
                }
                if !outcome.receipt.isEmpty { report.receipts.append(outcome.receipt) }
                report.outcomes.append("\(outcome.label): \(execution.succeeded && outcome.isComplete ? "정리 확인" : outcome.failureMessage)")
                try save(report)
                if !execution.succeeded || !outcome.isComplete { break }
            }
            // Reuse the same signed attribution collector as the action-history screen.
            // It records measured directory growth separately from file-age candidates.
            report.analysisAt = last?.analysisAt
            if enabled, !Task.isCancelled,
               requestedNow || report.analysisAt.map({ Date().timeIntervalSince($0) >= 86400 }) ?? true {
                detail = "캐시 처리 후 남은 공간 감소 원인을 분석하는 중"
                try save(report)
                let execution = context.execution
                if let invocation = execution.pinnedInvocation(relativePath: "scripts/storage_explain.py", name: "automatic_attribution"),
                   let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) {
                    let wrapper = "import sys; source=open(sys.argv[1],'rb').read(); sys.argv=['storage_explain.py']; exec(compile(source,'storage_explain.py','exec'),{'__name__':'__main__'})"
                    let analysis = await LocalProcessRunner.capture(executable: python,
                        arguments: ["-I", "-B", "-c", wrapper, invocation.argument],
                        currentDirectory: execution.runtimeRoot,
                        expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
                        expectedSignedBundleURL: execution.signedBundleURL, pinnedFiles: invocation.files,
                        timeout: 1800, maxOutputBytes: 8_000_000)
                    if analysis.succeeded,
                       let object = try? JSONSerialization.jsonObject(with: Data(analysis.output.utf8)) as? [String: Any],
                       let rows = object["rows"] as? [[String: Any]] {
                        report.analysisAt = Date()
                        let causes = AutomaticCachePolicy.evidenceLines(rows)
                        report.evidence += "\n" + causes.joined(separator: " · ")
                        report.outcomes.append("경로별 원인 분석 저장: 조치 기록 → 공간 확보 이후 무엇이 생겼나")
                    } else { report.outcomes.append("경로별 원인 분석 미완료 · 이전 결과를 현재 근거로 사용하지 않음") }
                } else { report.outcomes.append("원인 분석 실행환경 미확인") }
            }
            report.after = Self.freeSpace()
            report.finished = true
            try save(report)
            detail = Self.summary(report)
        } catch {
            detail = "자동 관리 중단: \(error.localizedDescription)"
            report.outcomes.append(detail)
            report.after = Self.freeSpace()
            try? save(report)
        }
        model.appendLog(detail)
        guard AutomaticCachePolicy.shouldNotify(report, previous: previousReport) else { return }
        let content = UNMutableNotificationContent()
        content.title = detail
        content.body = report.outcomes.suffix(3).joined(separator: "\n") + "\n" + report.evidence
        content.userInfo = ["modoreRoute": "storage"]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "modore-automatic-cache-recovery", content: content, trigger: nil))
        } catch { detail += " · 알림 전달 실패" }
    }
}
