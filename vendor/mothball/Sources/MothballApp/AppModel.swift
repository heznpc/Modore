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
    @Published var scanFailures: [ScanFailure] = []

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
        scanFailures = []
        let roots = scanLocations
        // Build a fresh scanner per scan so toggling `fetchBeforeArchive`
        // takes effect on the next scan without app restart.
        let scanner = RepoScanner(
            inspector: GitInspector(fetchBeforeInspect: fetchBeforeArchive)
        )
        let classifier = self.classifier
        Task { [weak self] in
            let report = await scanner.scanReport(roots: roots)
            let inspected = report.repos
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
                self?.scanFailures = report.failures.sorted {
                    $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending
                }
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
        let run = ArchiveRun(
            repos: request.repos,
            orchestrator: orchestrator,
            classifier: classifier,
            fetchBeforeArchive: fetchBeforeArchive,
            log: log
        )
        activeArchiveRun = run
        Task { [weak self, weak run] in
            guard let run else { return }
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
