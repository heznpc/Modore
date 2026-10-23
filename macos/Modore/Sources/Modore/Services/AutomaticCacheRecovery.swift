import AppKit

import Foundation
import UserNotifications

struct AutomaticCachePolicy {
    static let revision = 7
    static let recipes = [
        "vscode_update_cache", "chrome_code_sign_clones", "playwright_unused_browsers",
        "npm_download_cache", "pip_cache", "homebrew_cache", "uv_cache",
        "gradle_cache", "cocoapods_cache", "swiftpm_cache", "xcode_derived_data", "swift_build_outputs",
    ]

    static func largestFirst(_ candidates: [AutomaticRecoveryCandidate]) -> [AutomaticRecoveryCandidate] {
        candidates.filter { $0.ready && ($0.bytes ?? 0) >= 16 * 1_048_576 }
            .sorted { ($0.bytes ?? 0) == ($1.bytes ?? 0)
                ? $0.recipe < $1.recipe : ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    static func remainingBytes(after: Int64?) -> Int64? {
        after.map { max(0, target - max(0, $0)) }
    }

    static func occupants(_ rows: [[String: Any]]) -> [AutomaticStorageOccupant] {
        rows.compactMap { row -> AutomaticStorageOccupant? in
            guard let label = row["label"] as? String, let path = row["path"] as? String,
                  let bytes = row["allocatedBytes"] as? Int64, bytes >= 1_073_741_824 else { return nil }
            return AutomaticStorageOccupant(label: label, path: path, bytes: bytes,
                complete: row["complete"] as? Bool ?? false)
        }.sorted { $0.bytes > $1.bytes }
    }
    static func ownsStorageNotice(enabled: Bool, appRunning: Bool, free: Int64?) -> Bool {
        guard enabled, appRunning, let free else { return false }
        return free >= 3 * 1_073_741_824
    }

    static func shouldNotify(_ report: AutomaticCacheReport, previous: AutomaticCacheReport?) -> Bool {
        if !report.receipts.isEmpty { return true }
        guard let previous else { return true }
        if report.finished != previous.finished { return true }
        if (remainingBytes(after: report.after) == 0) != (remainingBytes(after: previous.after) == 0) { return true }
        let meaningful = { (rows: [String]) in rows.filter {
            !$0.hasPrefix("경로별 원인 분석 저장:") && !$0.hasPrefix("자동 정리로 목표에 도달하지 못했습니다.")
        } }
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

    // Leave headroom for swap and parallel builds before critical pressure.
    static let target: Int64 = 40 * 1_073_741_824
    static let criticalThreshold: Int64 = 2 * 1_073_741_824
    static let completedCooldown: TimeInterval = 600
    static let uncertainCooldown: TimeInterval = 86400

    static func shouldRun(enabled: Bool, free: Int64?, lastRun: Date?, now: Date,
                          previousFinished: Bool = true) -> Bool {
        guard enabled, let free, free < target else { return false }
        // Persisted dates prevent relaunch loops. Critical pressure gets a fresh
        // preview sooner; it never bypasses target/usage checks or receipts.
        // An interrupted run must not suppress recovery for another 30 minutes.
        // Keep a short retry delay; per-recipe uncertain attempts remain protected.
        let interval: TimeInterval = free < criticalThreshold || !previousFinished ? 60 : 1800
        return lastRun.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

struct AutomaticRecoveryCandidate: Codable, Identifiable {
    var recipe: String
    var label: String
    var bytes: Int64?
    var ready: Bool
    var reason: String
    var targets: [String]?
    var preservedTargets: [String]?
    var id: String { recipe }
}

struct AutomaticStorageOccupant: Codable, Identifiable {
    var label: String
    var path: String
    var bytes: Int64
    var complete: Bool
    var id: String { path }
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
    // Older reports recorded intent only; absence is not evidence of success.
    var completedAttempts: [String: Date]?
    var analysisAt: Date?
    var finished = false
    // Optional for reports written by earlier app versions.
    var policyRevision: Int?
    var candidates: [AutomaticRecoveryCandidate]?
    var occupants: [AutomaticStorageOccupant]?

    func cooldownReason(for recipe: String, now: Date) -> String? {
        guard let attempt = attempted[recipe] else { return nil }
        let elapsed = now.timeIntervalSince(attempt)
        if completedAttempts?[recipe] == attempt {
            guard elapsed < AutomaticCachePolicy.completedCooldown else { return nil }
            return "최근 정리 완료 · 반복 삭제 보류"
        }
        guard elapsed < AutomaticCachePolicy.uncertainCooldown else { return nil }
        return "이전 실행의 완료 여부 미확인 · 반복 삭제 보류"
    }

    mutating func beginAttempt(_ recipe: String, at date: Date) {
        attempted[recipe] = date
        completedAttempts?.removeValue(forKey: recipe)
    }

    /// Only the intact, matching pre-mutation rejection protocol permits a
    /// fresh preview on the next run. Partial/unknown execution may have moved
    /// files already, so retain its persisted intent across app restarts.
    @discardableResult
    mutating func finishAttempt(_ recipe: String, execution: CapturedProcessResult?) -> Bool {
        guard let execution else {
            attempted.removeValue(forKey: recipe)
            completedAttempts?.removeValue(forKey: recipe)
            return false
        }
        guard execution.endState == .exited, !execution.outputTruncated,
              let outcome = CleanupPreview(protocolText: execution.output),
              outcome.operation == "execute", outcome.recipeID == recipe else { return false }
        if execution.status == 3, outcome.status == "blocked",
           outcome.receipt.isEmpty, outcome.stagedRemainders.isEmpty,
           outcome.trashRun.isEmpty, (outcome.reclaimedBytes ?? 0) == 0 {
            attempted.removeValue(forKey: recipe)
            completedAttempts?.removeValue(forKey: recipe)
            return true
        }
        if execution.succeeded, outcome.isComplete, !outcome.receipt.isEmpty,
           let attempt = attempted[recipe] {
            if completedAttempts == nil { completedAttempts = [:] }
            completedAttempts?[recipe] = attempt
        }
        return false
    }
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
    @Published private(set) var last: AutomaticCacheReport?
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
            lastRun: last?.policyRevision == AutomaticCachePolicy.revision ? last?.date : nil,
            now: Date(), previousFinished: last?.finished ?? true)
    }

    static func freeSpace() -> Int64? {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (values?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static func summary(_ report: AutomaticCacheReport) -> String {
        guard let after = report.after else { return "자동 관리 결과의 여유 공간을 확인하지 못했습니다." }
        let delta = after - report.before
        let remaining = AutomaticCachePolicy.remainingBytes(after: after) ?? 0
        let state = remaining > 0 ? "공간 부족 지속 · 목표까지 \(StorageBytes.text(remaining)) 부족" : "공간 확보 목표 도달"
        return "\(report.date.formatted(date: .abbreviated, time: .shortened)) 기록 · 당시 \(StorageBytes.text(report.before)) → \(StorageBytes.text(after)) · 순변화 \(delta >= 0 ? "+" : "−")\(StorageBytes.text(abs(delta))) · \(state)"
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
        guard !CleanupExecutionService.isReviewOnly else { return }
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
              AutomaticCachePolicy.shouldRun(enabled: enabled, free: Self.freeSpace(),
                lastRun: requestedNow || last?.policyRevision != AutomaticCachePolicy.revision ? nil : last?.date,
                now: Date(), previousFinished: last?.finished ?? true),
              let before = Self.freeSpace() else { return }
        running = true
        model.cleanupInFlight = true
        model.beginDestructiveCleanupTransaction()
        var cleanupTransactionOpen = true
        defer {
            running = false
            if cleanupTransactionOpen {
                model.cleanupInFlight = false
                model.finishDestructiveCleanupTransaction()
            }
        }
        let fresh = snapshot.flatMap { Date().timeIntervalSince($0.date) < 60 ? $0 : nil }
        let top = fresh.flatMap { $0.cpuAvailable ? $0 : nil }?.processes.sorted { $0.cpu > $1.cpu }.prefix(3)
            .map { "\($0.name) \(Int($0.cpu))%" }.joined(separator: ", ") ?? "CPU 원인 미확인"
        let previousReport = last
        var report = AutomaticCacheReport(date: Date(), before: before,
            evidence: "\(fresh?.summary ?? "최근 상태 표본 없음") · CPU 상위: \(top). 캐시 점유는 회수 후보이며 공간 감소 원인으로 확정한 값은 아닙니다.",
            attempted: last?.attempted ?? [:], completedAttempts: last?.completedAttempts, analysisAt: last?.analysisAt,
            policyRevision: AutomaticCachePolicy.revision, candidates: [], occupants: last?.occupants)
        detail = "사용 중인 작업을 확인하고 다운로드 캐시를 분석하는 중"
        do {
            // Persist intent first: an app restart cannot immediately repeat deletion.
            try save(report)
            guard let context = await CleanupExecutionService.prepare(projectRoot: model.projectRoot) else {
                throw RetirementError(L10n.text("정리 실행 환경을 검증하지 못했습니다. Modore를 종료한 뒤 설치된 앱을 다시 열어 재시도하세요. 계속 실패하면 앱 설치 상태를 확인해야 합니다. 삭제는 시작하지 않았습니다."))
            }
            // Survey every supported regenerable category before deciding order.
            // Never let a small cache consume the run while GB-sized candidates
            // remain undiscovered. A preview is repeated immediately before deletion.
            for recipe in AutomaticCachePolicy.recipes {
                guard enabled, defaults.bool(forKey: "automaticSafeCacheRecovery"),
                      !Task.isCancelled, !model.applicationTerminationStarted else { break }
                if let reason = report.cooldownReason(for: recipe, now: Date()) {
                    report.candidates?.append(AutomaticRecoveryCandidate(recipe: recipe, label: recipe,
                        ready: false, reason: reason))
                    continue
                }
                detail = "정리 가능한 용량 측정 중 · \(recipe)"
                let result = await CleanupExecutionService.preview(recipeID: recipe, using: context)
                guard let preview = CleanupExecutionService.validatedPreview(result, recipeID: recipe) else {
                    let blocked = CleanupPreview(protocolText: result.output)
                    report.candidates?.append(AutomaticRecoveryCandidate(recipe: recipe,
                        label: blocked?.label ?? recipe, bytes: blocked?.estimateMeasured == true ? blocked?.estimatedBytes : nil, ready: false,
                        reason: (blocked?.blockedReason.isEmpty == false ? blocked!.blockedReason : "사용 여부·용량 측정 미완료")
                            + (blocked?.runningProcesses.isEmpty == false ? " · " + blocked!.runningProcesses : "")))
                    try save(report)
                    continue
                }
                report.candidates?.append(AutomaticRecoveryCandidate(recipe: recipe, label: preview.label,
                    bytes: preview.estimateMeasured ? preview.estimatedBytes : nil, ready: preview.canExecute,
                    reason: preview.canExecute ? "정리 가능" : (preview.blockedReason.isEmpty ? preview.statusText : preview.blockedReason),
                    targets: preview.targets, preservedTargets: preview.reviewResidue))
                try save(report)
            }
            for candidate in AutomaticCachePolicy.largestFirst(report.candidates ?? []) {
                let recipe = candidate.recipe
                guard enabled, defaults.bool(forKey: "automaticSafeCacheRecovery"),
                      !Task.isCancelled, !model.applicationTerminationStarted,
                      let available = Self.freeSpace(), available < AutomaticCachePolicy.target else { break }
                detail = "큰 항목부터 정리 중 · \(candidate.label)"
                let refreshed = await CleanupExecutionService.preview(recipeID: recipe, using: context)
                guard let preview = CleanupExecutionService.validatedPreview(refreshed, recipeID: recipe),
                      preview.canExecute, let size = preview.estimatedBytes, size >= 16 * 1_048_576 else {
                    report.outcomes.append("\(candidate.label): 사용 상태 또는 크기가 바뀌어 보존")
                    if let index = report.candidates?.firstIndex(where: { $0.recipe == recipe }) {
                        report.candidates?[index].ready = false
                        report.candidates?[index].reason = "사용 상태 또는 크기가 바뀌어 보존"
                    }
                    continue
                }
                guard enabled, defaults.bool(forKey: "automaticSafeCacheRecovery"), preview.approvalIsFresh(), model.persistCleanupMutationIntent() else { break }
                report.beginAttempt(recipe, at: Date())
                report.outcomes.append("\(preview.label): \(HealthSnapshot.bytes(size)) 처리 시작")
                try save(report)
                let execution = await CleanupExecutionService.execute(preview, using: context)
                let rejectedBeforeMutation = report.finishAttempt(recipe, execution: execution)
                guard let execution else {
                    // No process launched (e.g. foreground cleanup owns the lease).
                    // Do not turn contention into a full day of suppressed retries.
                    report.outcomes.append("\(recipe): 다른 정리 또는 승인 검증으로 실행 보류 · 다음 점검에서 재확인")
                    try save(report)
                    break
                }
                guard let outcome = CleanupPreview(protocolText: execution.output),
                      outcome.recipeID == recipe else {
                    report.outcomes.append("\(recipe): 실행 결과 미확인 · 재실행 중단"); break
                }
                if !outcome.receipt.isEmpty { report.receipts.append(outcome.receipt) }
                let resultText = execution.succeeded && outcome.isComplete
                    ? "정리 확인 · 제거한 산출물 \(StorageBytes.text(outcome.reclaimedBytes)) · 볼륨 변화 \(StorageBytes.text(outcome.physicalDeltaBytes))"
                    : outcome.failureMessage + (rejectedBeforeMutation ? " · 삭제 전 차단됨 · 다음 점검에서 다시 측정" : "")
                report.outcomes.append("\(outcome.label): \(resultText)")
                if let index = report.candidates?.firstIndex(where: { $0.recipe == recipe }) {
                    report.candidates?[index].ready = false
                    report.candidates?[index].reason = resultText
                }
                try save(report)
                // A stale preview for one category must not starve other safe
                // candidates. Do not retry the same category in this run.
                if rejectedBeforeMutation { continue }
                if !execution.succeeded || !outcome.isComplete { break }
            }
            // Commit the cleanup result before optional, potentially slow analysis.
            // Exiting during a read-only scan must not turn successful deletion into
            // an interrupted cleanup, or fold later disk writes into its result.
            report.after = Self.freeSpace()
            report.finished = true
            if let missing = AutomaticCachePolicy.remainingBytes(after: report.after), missing > 0 {
                report.outcomes.append("자동 정리로 목표에 도달하지 못했습니다. 추가 필요: \(HealthSnapshot.bytes(missing)). 남은 큰 항목은 확보 계획에서 확인할 수 있습니다.")
            }
            try save(report)
            model.cleanupInFlight = false
            model.finishDestructiveCleanupTransaction()
            cleanupTransactionOpen = false
            detail = Self.summary(report)

            // Reuse the same native attribution collector as the action-history screen.
            // It records measured directory growth separately from file-age candidates.
            report.analysisAt = last?.analysisAt
            if enabled, !Task.isCancelled,
               requestedNow || report.occupants == nil || !report.receipts.isEmpty || report.analysisAt.map({ Date().timeIntervalSince($0) >= 86400 }) ?? true {
                detail = Self.summary(report) + " · 정리 종료 후 원인 분석 중"
                do {
                    let analysis = try await StorageAttributionService.run()
                    let data = try JSONEncoder().encode(analysis)
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let rows = object["rows"] as? [[String: Any]] {
                        report.analysisAt = Date()
                        report.occupants = AutomaticCachePolicy.occupants(rows)
                        let causes = AutomaticCachePolicy.evidenceLines(rows)
                        report.evidence += "\n" + causes.joined(separator: " · ")
                        report.outcomes.append("경로별 원인 분석 저장: 조치 기록 → 공간 확보 이후 무엇이 생겼나")
                    }
                } catch {
                    report.outcomes.append("경로별 원인 분석 미완료 · 이전 결과를 현재 근거로 사용하지 않음")
                }
            }
            try save(report)
            detail = Self.summary(report)
        } catch {
            detail = report.finished
                ? Self.summary(report) + " · 후속 기록 저장 실패: \(error.localizedDescription)"
                : "자동 관리 중단: \(error.localizedDescription)"
            report.outcomes.append(detail)
            if !report.finished { report.after = Self.freeSpace() }
            try? save(report)
        }
        model.appendLog(detail)
        guard AutomaticCachePolicy.shouldNotify(report, previous: previousReport) else { return }
        let content = UNMutableNotificationContent()
        let notice = ResourceNotice.automaticRecovery(report)
        content.title = notice.title
        content.body = notice.body
        content.userInfo = ["modoreRoute": notice.route]
        content.categoryIdentifier = PressureNotification.category
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: PressureNotification.category, content: content, trigger: nil))
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["modore-automatic-cache-recovery"])
        } catch { detail += " · 알림 전달 실패" }
    }
}
