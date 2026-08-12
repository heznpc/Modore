import Foundation
import MothballCore

/// Connects scree's already-discovered workspace paths to MothballCore's
/// own read-only repo scanner and safety classifier -- the "real consumer"
/// deferred when MothballCore was first linked into Modore's build graph.
/// Read-only: MothballCore's scanner only runs `git log`/`status`/`config`/
/// `rev-parse`/`rev-list` (no `fetch` -- GitInspector defaults that off),
/// and this connection stops at display. Archiving (compress + trash the
/// original) is Mothball's own standalone app; wiring that destructive
/// action into Modore is deliberately a separate, later step, the same
/// display-first precedent scree's own first UI integration set.
enum MothballService {
    /// Every lineage path scree already confirmed both exists and is a git
    /// repo becomes one scan root. Pure and independently testable. `limit`
    /// keeps a pathological session history (thousands of distinct
    /// workspaces) from turning one page load into an unbounded git-process
    /// fan-out.
    static func candidateRoots(from lineagePaths: [ScreeLineagePath], limit: Int = 300) -> [URL] {
        lineagePaths
            .filter { $0.exists && $0.hasGit }
            .prefix(limit)
            .map { URL(fileURLWithPath: $0.path) }
    }

    /// Pure and independently testable: which scanned repos are worth
    /// showing as archive candidates, and in what order. `.unsafe` repos
    /// (actively used, or unrecoverable if archived -- no remote, or dirty/
    /// unpushed work) are never shown here; this list exists to surface
    /// what is worth considering, not a dump of every repo scree ever saw.
    static func rankCandidates(
        repos: [RepoInfo],
        classifier: SafetyClassifier = SafetyClassifier(),
        now: Date = Date()
    ) -> [ArchiveCandidate] {
        repos
            .compactMap { repo -> ArchiveCandidate? in
                let verdict = classifier.classify(repo, now: now)
                guard verdict.tier != .unsafe else { return nil }
                let dormancyDays = max(0, Int(now.timeIntervalSince(repo.lastActivity) / 86_400))
                return ArchiveCandidate(repo: repo, verdict: verdict, dormancyDays: dormancyDays)
            }
            .sorted { $0.repo.sizeBytes > $1.repo.sizeBytes }
    }

    static func scanCandidates(lineagePaths: [ScreeLineagePath]) async -> [ArchiveCandidate] {
        let roots = candidateRoots(from: lineagePaths)
        guard !roots.isEmpty else { return [] }
        let repos = await RepoScanner().scan(roots: roots)
        return rankCandidates(repos: repos)
    }
}

extension ScanModel {
    func refreshArchiveCandidates() {
        guard !archiveLoading else { return }
        guard let report = screeReport else {
            archiveError = "먼저 AI 세션 감사를 실행하세요."
            return
        }
        archiveLoading = true
        archiveError = nil
        let paths = report.lineagePaths
        Task {
            defer { archiveLoading = false }
            archiveCandidates = await MothballService.scanCandidates(lineagePaths: paths)
        }
    }
}
