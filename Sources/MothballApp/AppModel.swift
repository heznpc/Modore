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
        didSet { defaults.set(hasAcceptedFirstRun, forKey: Keys.firstRunAccepted) }
    }

    // User-chosen archive destination directory.
    @Published var archiveDirectory: URL {
        didSet { defaults.set(archiveDirectory.path, forKey: Keys.archiveDirectory) }
    }

    @Published var scanLocations: [URL] = []
    @Published var scanState: ScanState = .idle
    @Published var inspectedRepos: [InspectedRepo] = []

    @Published var confirmation: ConfirmRequest?
    @Published var activeArchiveRun: ArchiveRun?
    @Published var lastArchiveSummary: ArchiveSummary?

    private let defaults: UserDefaults
    private let scanner: RepoScanner
    private let classifier: SafetyClassifier

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAcceptedFirstRun = defaults.bool(forKey: Keys.firstRunAccepted)

        let defaultArchive = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Archive", directoryHint: .isDirectory)
        if let stored = defaults.string(forKey: Keys.archiveDirectory) {
            self.archiveDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            self.archiveDirectory = defaultArchive
        }

        self.scanner = RepoScanner()
        self.classifier = SafetyClassifier()
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
        let scanner = self.scanner
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

    var selectedTotalBytes: Int64 {
        selectedRepos.reduce(0) { $0 + $1.info.sizeBytes }
    }

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
        let run = ArchiveRun(repos: request.repos, orchestrator: orchestrator)
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

    private enum Keys {
        static let firstRunAccepted = "Mothball.firstRunAccepted"
        static let archiveDirectory = "Mothball.archiveDirectory"
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

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let repos: [InspectedRepo]
    let archiveDirectory: URL

    var totalBytes: Int64 { repos.reduce(0) { $0 + $1.info.sizeBytes } }
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
    @Published private(set) var currentStep: String = ""
    @Published private(set) var results: [PerRepoResult]

    private let repos: [InspectedRepo]
    private let orchestrator: ArchiveOrchestrator

    init(repos: [InspectedRepo], orchestrator: ArchiveOrchestrator) {
        self.repos = repos
        self.orchestrator = orchestrator
        self.total = repos.count
        self.results = repos.map { PerRepoResult(repoPath: $0.info.path) }
    }

    fileprivate func execute() async {
        for (index, repo) in repos.enumerated() {
            currentRepoName = repo.info.path.lastPathComponent
            currentStep = "준비 중"

            do {
                let result = try await orchestrator.archive(repo.info) { [weak self] step in
                    Task { @MainActor [weak self] in
                        self?.currentStep = describe(step)
                    }
                }
                results[index].success = result
            } catch {
                results[index].failure = error
            }
            completedCount = index + 1
        }
        currentStep = "완료"
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

private func describe(_ step: ArchiveOrchestrator.Step) -> String {
    switch step {
    case .starting:                  return "시작"
    case .compressing:               return "압축 중"
    case .verifying:                 return "검증 중"
    case .writingManifest:           return "메타데이터 기록"
    case .movingOriginalToTrash:    return "원본 휴지통 이동"
    case .completed:                 return "완료"
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
