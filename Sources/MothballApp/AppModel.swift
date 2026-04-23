import Foundation
import SwiftUI
import MothballCore

/// Single source of truth for the app's UI state. All mutations happen
/// on the main actor; long-running work hops to background actors via
/// `await` and writes results back here.
@MainActor
final class AppModel: ObservableObject {
    // First-run consent. Persisted in UserDefaults so we only ask once.
    @Published var hasAcceptedFirstRun: Bool {
        didSet { defaults.set(hasAcceptedFirstRun, forKey: Keys.firstRunAccepted.rawValue) }
    }

    // User-chosen archive destination directory.
    @Published var archiveDirectory: URL {
        didSet { defaults.set(archiveDirectory.path, forKey: Keys.archiveDirectory.rawValue) }
    }

    // When true, every scan runs `git fetch` per repo before reading
    // upstream state. Slower and requires network; off by default.
    @Published var fetchBeforeArchive: Bool {
        didSet { defaults.set(fetchBeforeArchive, forKey: Keys.fetchBeforeArchive.rawValue) }
    }

    @Published var scanLocations: [URL] = []
    @Published var scanState: ScanState = .idle
    @Published var inspectedRepos: [InspectedRepo] = []

    @Published var confirmation: ConfirmRequest?
    @Published var activeArchiveRun: ArchiveRun?
    @Published var lastArchiveSummary: ArchiveSummary?

    private let defaults: UserDefaults
    private let classifier: SafetyClassifier
    private let log: ActivityLog?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAcceptedFirstRun = defaults.bool(forKey: Keys.firstRunAccepted.rawValue)
        self.fetchBeforeArchive = defaults.bool(forKey: Keys.fetchBeforeArchive.rawValue)

        let defaultArchive = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Archive", directoryHint: .isDirectory)
        if let stored = defaults.string(forKey: Keys.archiveDirectory.rawValue) {
            self.archiveDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            self.archiveDirectory = defaultArchive
        }

        self.classifier = SafetyClassifier()
        // Failure to open the log shouldn't keep the app from starting —
        // we just lose the audit trail for this session.
        self.log = try? ActivityLog.userDefault()
    }

    // MARK: - Scan locations

    func addScanLocation(_ url: URL) {
        guard !scanLocations.contains(url) else { return }
        scanLocations.append(url)
    }

    func removeScanLocation(_ url: URL) {
        scanLocations.removeAll { $0 == url }
    }

    // MARK: - Scanning

    func runScan() {
        guard !scanLocations.isEmpty else { return }
        scanState = .running
        inspectedRepos = []
        let roots = scanLocations
        // Build a fresh scanner per scan so toggling `fetchBeforeArchive`
        // takes effect on the next scan without app restart.
        let scanner = RepoScanner(
            inspector: GitInspector(fetchBeforeInspect: fetchBeforeArchive)
        )
        let classifier = self.classifier
        Task { [weak self] in
            let infos = await scanner.scan(roots: roots)
            let inspected = infos
                .map { info -> InspectedRepo in
                    let verdict = classifier.classify(info)
                    return InspectedRepo(
                        info: info,
                        verdict: verdict,
                        isSelected: verdict.tier == .safe
                    )
                }
                .sorted { $0.info.sizeBytes > $1.info.sizeBytes }
            await MainActor.run { [weak self] in
                self?.inspectedRepos = inspected
                self?.scanState = .done
            }
        }
    }

    func toggleSelection(of repoID: URL) {
        guard let idx = inspectedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        guard inspectedRepos[idx].verdict.tier != .unsafe else { return }
        inspectedRepos[idx].isSelected.toggle()
    }

    var selectedRepos: [InspectedRepo] {
        inspectedRepos.filter(\.isSelected)
    }

    var selectedTotalBytes: Int64 { selectedRepos.totalBytes }

    // MARK: - Archive flow

    func requestArchiveConfirmation() {
        guard !selectedRepos.isEmpty else { return }
        confirmation = ConfirmRequest(
            repos: selectedRepos,
            archiveDirectory: archiveDirectory
        )
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    func confirmAndStartArchive() {
        guard let request = confirmation else { return }
        confirmation = nil
        let orchestrator = ArchiveOrchestrator(configuration: .init(
            archiveDirectory: archiveDirectory
        ))
        let run = ArchiveRun(repos: request.repos, orchestrator: orchestrator, log: log)
        activeArchiveRun = run
        Task { [weak self] in
            await run.execute()
            await MainActor.run { [weak self] in
                self?.activeArchiveRun = nil
                self?.lastArchiveSummary = run.summary
                let succeededPaths = Set(
                    run.results.filter { $0.success != nil }.map(\.repoPath)
                )
                self?.inspectedRepos.removeAll { succeededPaths.contains($0.info.path) }
            }
        }
    }

    func dismissArchiveSummary() {
        lastArchiveSummary = nil
    }

    // MARK: -

    private enum Keys: String {
        case firstRunAccepted = "Mothball.firstRunAccepted"
        case archiveDirectory = "Mothball.archiveDirectory"
        case fetchBeforeArchive = "Mothball.fetchBeforeArchive"
    }
}

// MARK: - View-model types

enum ScanState: Equatable {
    case idle, running, done
}

struct InspectedRepo: Identifiable, Equatable {
    let info: RepoInfo
    let verdict: SafetyVerdict
    var isSelected: Bool
    var id: URL { info.path }
}

extension Sequence where Element == InspectedRepo {
    var totalBytes: Int64 { reduce(0) { $0 + $1.info.sizeBytes } }
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let repos: [InspectedRepo]
    let archiveDirectory: URL

    var totalBytes: Int64 { repos.totalBytes }
    var hasCautionItems: Bool { repos.contains { $0.verdict.tier == .caution } }
    var cautionCount: Int { repos.filter { $0.verdict.tier == .caution }.count }
}

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

    private let repos: [InspectedRepo]
    private let orchestrator: ArchiveOrchestrator
    private let log: ActivityLog?

    init(repos: [InspectedRepo], orchestrator: ArchiveOrchestrator, log: ActivityLog?) {
        self.repos = repos
        self.orchestrator = orchestrator
        self.log = log
        self.total = repos.count
        self.results = repos.map { PerRepoResult(repoPath: $0.info.path) }
    }

    fileprivate func execute() async {
        for (index, repo) in repos.enumerated() {
            currentRepoName = repo.info.path.lastPathComponent
            currentStep = .preparing

            await log?.append(.archiveStart(
                path: repo.info.path,
                sizeBytes: repo.info.sizeBytes
            ))

            do {
                let result = try await orchestrator.archive(repo.info) { [weak self] step in
                    let mapped = ArchiveStep(step)
                    Task { @MainActor [weak self] in
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
            } catch {
                await log?.append(.archiveFailed(
                    path: repo.info.path,
                    error: String(describing: error)
                ))
                results[index].failure = error
            }
            completedCount = index + 1
        }
        currentStep = .completed
    }

    var summary: ArchiveSummary {
        let succeeded = results.filter { $0.success != nil }.count
        let bytesFreed = results.compactMap(\.success).reduce(Int64(0)) { $0 + $1.archiveBytes }
        return ArchiveSummary(
            attempted: total,
            succeeded: succeeded,
            failed: total - succeeded,
            bytesFreed: bytesFreed
        )
    }
}

enum ArchiveStep: Equatable {
    case preparing
    case compressing
    case verifying
    case writingManifest
    case movingToTrash
    case completed

    init(_ step: ArchiveOrchestrator.Step) {
        switch step {
        case .starting:                self = .preparing
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

    static func == (lhs: PerRepoResult, rhs: PerRepoResult) -> Bool {
        lhs.repoPath == rhs.repoPath
            && lhs.success == rhs.success
            && (lhs.failure == nil) == (rhs.failure == nil)
    }
}

struct ArchiveSummary: Equatable {
    let attempted: Int
    let succeeded: Int
    let failed: Int
    let bytesFreed: Int64
}
