import Foundation
import SwiftUI
import MothballCore

/// Drives a sequence of single-repo archive operations and exposes
/// progress as `@Published` state so SwiftUI can observe it.
@MainActor
final class ArchiveRun: ObservableObject, Identifiable {
    let id = UUID()
    let total: Int

    @Published private(set) var completedCount: Int = 0
    @Published private(set) var currentRepoName: String = ""
    @Published private(set) var currentStep: ArchiveStep = .preparing
    @Published private(set) var results: [PerRepoResult]
    @Published private(set) var isCancellationRequested = false
    @Published private(set) var isFinished = false

    private let repos: [InspectedRepo]
    private let continuity: [URL: ContinuityAssessment]
    private let orchestrator: ArchiveOrchestrator
    private let classifier: SafetyClassifier
    private let preflightScanner: RepoScanner
    private let log: ActivityLog?

    /// - Parameter continuity: per-repo session assessments, keyed by
    ///   repo path. Standalone Mothball has no session binder — it scans
    ///   git repositories, not `~/.claude` — so this map is empty when
    ///   the app runs on its own and every repo falls to
    ///   `.notAssessed`, which the gate refuses. Modore, which does run
    ///   a binder, supplies real assessments.
    init(
        repos: [InspectedRepo],
        continuity: [URL: ContinuityAssessment] = [:],
        orchestrator: ArchiveOrchestrator,
        classifier: SafetyClassifier,
        fetchBeforeArchive: Bool,
        log: ActivityLog?
    ) {
        self.repos = repos
        self.continuity = continuity
        self.orchestrator = orchestrator
        self.classifier = classifier
        self.preflightScanner = RepoScanner(
            inspector: GitInspector(fetchBeforeInspect: fetchBeforeArchive)
        )
        self.log = log
        self.total = repos.count
        self.results = repos.map { PerRepoResult(repoPath: $0.info.path) }
    }

    func requestCancellation() {
        isCancellationRequested = true
    }

    func execute() async {
        for (index, repo) in repos.enumerated() {
            if isCancellationRequested {
                markSkipped(from: index)
                break
            }

            currentRepoName = repo.info.path.lastPathComponent
            currentStep = .preparing

            await log?.append(.archiveStart(
                path: repo.info.path,
                sizeBytes: repo.info.sizeBytes
            ))

            do {
                let freshInfo = try await preflight(repo)
                // `.notAssessed`, not an override. An override is a record
                // that a person was shown the gap and chose to proceed;
                // writing one automatically puts a human decision in the
                // manifest that no human made, and turns the fail-closed
                // gate into a formality that always passes. Standalone
                // Mothball has no binder, so it refuses and says why.
                let requested = continuity[repo.info.path] ?? .notAssessed
                // Seal before archiving, and clean the staging tree up
                // afterwards whichever way the archive goes. Sealing is
                // the step that makes `.bindings` archivable at all, so
                // without it a caller that did the binding work still
                // hits the gate.
                let prepared = try ContinuityPreparation.seal(
                    requested,
                    stagingParent: orchestrator.configuration.archiveDirectory
                )
                defer {
                    if let staging = prepared.stagingRoot {
                        try? FileManager.default.removeItem(at: staging)
                    }
                }
                let assessment = prepared.assessment
                let result = try await orchestrator.archive(freshInfo, continuity: assessment) { [weak self] step in
                    let mapped = ArchiveStep(step)
                    await MainActor.run { [weak self] in
                        // Same orchestrator step can fire repeatedly (e.g.
                        // .compressing during a long tar run); avoid
                        // republishing identical values to keep SwiftUI
                        // diffing cheap and the Combine traffic quiet.
                        guard let self, self.currentStep != mapped else { return }
                        self.currentStep = mapped
                    }
                }
                await log?.append(.archiveSuccess(
                    archive: result.archive,
                    sourceBytes: result.originalBytes,
                    archiveBytes: result.archiveBytes
                ))
                await log?.append(.trashed(path: repo.info.path))
                results[index].success = result
            } catch ArchiveOrchestrator.ArchiveError.trashFailed(let path, let underlying) {
                // Archive promoted to its final path successfully; only
                // the trash step failed. Log the distinction so a user
                // grepping the log later can tell "archive worked, just
                // delete the original yourself" from a real failure.
                await log?.append(.trashFailed(
                    path: path,
                    error: String(describing: underlying)
                ))
                results[index].failure = ArchiveOrchestrator.ArchiveError
                    .trashFailed(path, underlying: underlying)
            } catch ArchiveOrchestrator.ArchiveError.continuityRefused(let refusal) {
                // Every refusal here is recoverable by running one more
                // step, and `String(describing:)` on the enum would print
                // a case name instead of saying which step. This is the
                // one error a user is expected to hit and act on.
                await log?.append(.archiveFailed(
                    path: repo.info.path,
                    error: refusal.message
                ))
                results[index].failure = ArchiveOrchestrator.ArchiveError
                    .continuityRefused(refusal)
            } catch {
                await log?.append(.archiveFailed(
                    path: repo.info.path,
                    error: String(describing: error)
                ))
                results[index].failure = error
            }
            completedCount = index + 1

            if isCancellationRequested {
                markSkipped(from: index + 1)
                break
            }
        }
        currentStep = .completed
        isFinished = true
    }

    var summary: ArchiveSummary {
        let succeeded = results.filter { $0.success != nil }.count
        let failed = results.filter { $0.failure != nil }.count
        let skipped = results.filter(\.wasSkipped).count
        let bytesFreed = results.compactMap(\.success).reduce(Int64(0)) {
            $0 + max(0, $1.originalBytes - $1.archiveBytes)
        }
        return ArchiveSummary(
            attempted: total - skipped,
            succeeded: succeeded,
            failed: failed,
            skipped: skipped,
            bytesFreed: bytesFreed,
            results: results
        )
    }

    private func preflight(_ repo: InspectedRepo) async throws -> RepoInfo {
        let report = await preflightScanner.scanReport(roots: [repo.info.path])
        guard let freshInfo = report.repos.first(where: { $0.path.standardizedFileURL == repo.info.path.standardizedFileURL }) else {
            if let failure = report.failures.first {
                throw ArchivePreflightError.inspectionFailed(failure.path, reason: failure.reason)
            }
            throw ArchivePreflightError.repoUnavailable(repo.info.path)
        }

        let freshVerdict = classifier.classify(freshInfo)
        if freshVerdict.tier == .unsafe {
            throw ArchivePreflightError.becameUnsafe(freshInfo.path, verdict: freshVerdict)
        }
        if repo.verdict.tier == .safe && freshVerdict.tier == .caution {
            throw ArchivePreflightError.needsRenewedConfirmation(freshInfo.path, verdict: freshVerdict)
        }
        return freshInfo
    }

    private func markSkipped(from start: Int) {
        guard start < results.count else { return }
        for index in start..<results.count {
            if results[index].success == nil && results[index].failure == nil {
                results[index].wasSkipped = true
            }
        }
    }
}

enum ArchiveStep: Equatable {
    case preparing
    case sealingSessions
    case compressing
    case verifying
    case writingManifest
    case movingToTrash
    case completed

    init(_ step: ArchiveOrchestrator.Step) {
        switch step {
        case .starting:                self = .preparing
        case .sealingSessions:         self = .sealingSessions
        case .compressing:             self = .compressing
        case .verifying:               self = .verifying
        case .writingManifest:         self = .writingManifest
        case .movingOriginalToTrash:   self = .movingToTrash
        case .completed:               self = .completed
        }
    }

    var localizedLabel: String {
        switch self {
        case .preparing:        return "준비 중"
        case .sealingSessions:  return "AI 세션 봉인 중"
        case .compressing:      return "압축 중"
        case .verifying:        return "검증 중"
        case .writingManifest:  return "메타데이터 기록"
        case .movingToTrash:    return "원본 휴지통 이동"
        case .completed:        return "완료"
        }
    }
}

struct PerRepoResult: Identifiable, Equatable {
    let repoPath: URL
    var id: URL { repoPath }
    var success: ArchiveOrchestrator.ArchiveResult?
    var failure: Error?
    var wasSkipped: Bool = false

    static func == (lhs: PerRepoResult, rhs: PerRepoResult) -> Bool {
        lhs.repoPath == rhs.repoPath
            && lhs.success == rhs.success
            && (lhs.failure == nil) == (rhs.failure == nil)
            && lhs.wasSkipped == rhs.wasSkipped
    }
}

struct ArchiveSummary: Identifiable, Equatable {
    let id = UUID()
    let attempted: Int
    let succeeded: Int
    let failed: Int
    let skipped: Int
    let bytesFreed: Int64
    let results: [PerRepoResult]

    static func == (lhs: ArchiveSummary, rhs: ArchiveSummary) -> Bool {
        lhs.attempted == rhs.attempted
            && lhs.succeeded == rhs.succeeded
            && lhs.failed == rhs.failed
            && lhs.skipped == rhs.skipped
            && lhs.bytesFreed == rhs.bytesFreed
            && lhs.results == rhs.results
    }
}

enum ArchivePreflightError: LocalizedError, Sendable {
    case repoUnavailable(URL)
    case inspectionFailed(URL, reason: String)
    case becameUnsafe(URL, verdict: SafetyVerdict)
    case needsRenewedConfirmation(URL, verdict: SafetyVerdict)

    var errorDescription: String? {
        let formatter = SafetyReasonFormatter()
        switch self {
        case .repoUnavailable(let path):
            return "\(path.lastPathComponent): 아카이브 직전 저장소를 다시 찾을 수 없습니다."
        case .inspectionFailed(let path, let reason):
            return "\(path.lastPathComponent): 아카이브 직전 검사 실패 (\(reason))"
        case .becameUnsafe(let path, let verdict):
            return "\(path.lastPathComponent): 아카이브 직전 보관 금지로 변경됨 - \(formatter.string(for: verdict))"
        case .needsRenewedConfirmation(let path, let verdict):
            return "\(path.lastPathComponent): 안전 판정이 주의로 변경되어 다시 확인이 필요함 - \(formatter.string(for: verdict))"
        }
    }
}
